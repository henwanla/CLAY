// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/adapters/gonet"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/nat"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/inbound"
)

var demoEndpoint = netip.MustParseAddrPort("198.51.100.42:18080")
var tcpTarget = demoEndpoint.Addr().As4()
var udpTarget = netip.MustParseAddr("198.51.100.53")

const syntheticTCPReplyBudget = 8 * time.Second

// These authenticated upstream listeners never dial any target. They answer
// only the fixed test payloads at the two reserved addresses.
type protocolEcho struct {
	label string
	table C.NatTable
}

func (e *protocolEcho) NatTable() C.NatTable { return e.table }

func (e *protocolEcho) HandleTCPConn(conn net.Conn, target *C.Metadata) {
	defer conn.Close()
	if target.DstIP.Unmap() != netip.AddrFrom4(tcpTarget) || target.DstPort != 18080 || target.Host != "" {
		return
	}
	_ = conn.SetDeadline(time.Now().Add(syntheticTCPReplyBudget))
	payload := make([]byte, len("synthetic-packet"))
	if _, err := io.ReadFull(conn, payload); err == nil && string(payload) == "synthetic-packet" {
		_, _ = io.WriteString(conn, e.label)
	}
}

func (e *protocolEcho) HandleUDPPacket(packet C.UDPPacket, target *C.Metadata) {
	defer packet.Drop()
	if target.DstIP.Unmap() == udpTarget && target.DstPort == 53 && target.Host == "" && string(packet.Data()) == "packet-proof" {
		_, _ = packet.WriteBack([]byte(e.label), net.UDPAddrFromAddrPort(netip.AddrPortFrom(udpTarget, 53)))
	}
}

func normalizedFixtures(t *testing.T, nodes ...map[string]any) []byte {
	t.Helper()
	data, err := json.Marshal(map[string]any{"proxies": nodes})
	if err != nil {
		t.Fatal("unable to encode synthetic nodes")
	}
	binary := os.Getenv("CLAY_PACKET_FIXTURE_IMPORTER")
	if binary == "" {
		t.Fatal("use Engine/build.sh host-test to run against the shared Swift importer")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "--packet-profile-stdin")
	cmd.Stdin = bytes.NewReader(data)
	result, err := cmd.Output()
	if err != nil || len(result) == 0 || len(result) > maxProfileBytes {
		t.Fatal("shared Swift importer rejected the synthetic nodes")
	}
	return result
}

func cloneFields(source map[string]any) map[string]any {
	fields := make(map[string]any, len(source))
	for key, value := range source {
		fields[key] = value
	}
	return fields
}

func syntheticSSKey(size int, value byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{value}, size))
}

func sharedLoopbackPort(t *testing.T) string {
	t.Helper()
	ip := net.IPv4(127, 0, 0, 1)
	for attempt := 0; attempt < 5; attempt++ {
		tcp, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: ip})
		if err != nil {
			t.Fatal("unable to reserve a test TCP port")
		}
		port := tcp.Addr().(*net.TCPAddr).Port
		udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: ip, Port: port})
		_ = tcp.Close()
		if err == nil {
			_ = udp.Close()
			return strconv.Itoa(port)
		}
	}
	t.Fatal("unable to reserve a shared test port")
	return ""
}

func TestImportedProtocols(t *testing.T) {
	// No external CA, account data, forwarding or real DNS is involved.
	cert, private, pin, err := ca.NewRandomTLSKeyPair(ca.KeyPairTypeP256)
	if err != nil {
		t.Fatal("synthetic certificate creation failed")
	}
	const account = "478733c8-afad-47f1-8ee0-cee758e7447f"
	const password = "generated-for-local-test"
	const obfsPassword = "private-loopback-test"
	var nodes []map[string]any
	var variants []struct {
		label string
		udp   bool
	}
	add := func(label string, listener C.InboundListener, err error, fields map[string]any, udp bool) {
		t.Helper()
		if err != nil {
			t.Fatalf("%s server constructor failed", label)
		}
		if listener.Listen(&protocolEcho{label: label, table: nat.New()}) != nil {
			t.Fatalf("%s loopback listener failed", label)
		}
		t.Cleanup(func() { _ = listener.Close() })
		addresses := strings.Split(listener.Address(), ",")
		addr, err := netip.ParseAddrPort(addresses[0])
		if err != nil || addr.Addr() != netip.MustParseAddr("127.0.0.1") || addr.Port() == 0 {
			t.Fatalf("%s expected a unique IPv4 loopback listener", label)
		}
		for _, address := range addresses[1:] {
			if address != addr.String() {
				t.Fatalf("%s expected TCP and UDP on the same loopback port", label)
			}
		}
		fields["name"], fields["server"], fields["port"] = label, "127.0.0.1", int(addr.Port())
		nodes = append(nodes, fields)
		variants = append(variants, struct {
			label string
			udp   bool
		}{label, udp})
	}
	base := func(kind string) inbound.BaseOption {
		return inbound.BaseOption{NameStr: kind, Listen: "127.0.0.1", Port: "0"}
	}
	vmess, err := inbound.NewVmess(&inbound.VmessOption{BaseOption: base("vmess"), Users: []inbound.VmessUser{{Username: "fixture", UUID: account}}})
	add("vmess-tcp", vmess, err, map[string]any{"type": "vmess", "uuid": account, "cipher": "auto", "udp": true}, true)
	// Clear VLESS is used only on this non-forwarding loopback fixture.
	vless, err := inbound.NewVless(&inbound.VlessOption{BaseOption: base("vless"), AllowInsecure: true,
		Users: []inbound.VlessUser{{Username: "fixture", UUID: account}}})
	add("vless-tcp", vless, err, map[string]any{"type": "vless", "uuid": account, "udp": true, "packet-encoding": "xudp"}, true)
	ss, err := inbound.NewShadowSocks(&inbound.ShadowSocksOption{BaseOption: base("ss"), Cipher: "aes-128-gcm", Password: password})
	add("ss-aead", ss, err, map[string]any{"type": "ss", "cipher": "aes-128-gcm", "password": password}, false)
	ssIdentityIndex := 0
	for _, variant := range []struct {
		label, cipher string
		keyBytes      int
		identity      bool
	}{
		{"ss2022-aes128", "2022-blake3-aes-128-gcm", 16, false},
		{"ss2022-aes256", "2022-blake3-aes-256-gcm", 32, false},
		{"ss2022-chacha20", "2022-blake3-chacha20-poly1305", 32, false},
		{"ss2022-aes128-identity", "2022-blake3-aes-128-gcm", 16, true},
		{"ss2022-aes256-identity", "2022-blake3-aes-256-gcm", 32, true},
	} {
		server := syntheticSSKey(variant.keyBytes, 0xFA)
		password := server
		option := &inbound.ShadowSocksOption{BaseOption: base("ss2022"), Cipher: variant.cipher, Password: server, UDP: true}
		option.Port = sharedLoopbackPort(t)
		if variant.identity {
			user := syntheticSSKey(variant.keyBytes, 0xFB)
			password += ":" + user
			option.Users = map[string]string{"fixture": user}
			ssIdentityIndex = len(nodes)
		}
		listener, err := inbound.NewShadowSocks(option)
		add(variant.label, listener, err, map[string]any{"type": "ss", "cipher": variant.cipher, "password": password, "udp": true}, true)
	}
	trojanIndex := len(nodes)
	trojan, err := inbound.NewTrojan(&inbound.TrojanOption{BaseOption: base("trojan"),
		Certificate: cert, PrivateKey: private, Users: []inbound.TrojanUser{{Username: "fixture", Password: password}}})
	add("trojan-tls", trojan, err, map[string]any{"type": "trojan", "password": password, "fingerprint": pin, "udp": true}, true)
	hy2Index := len(nodes)
	for _, obfs := range []string{"", "salamander", "gecko"} {
		label := "hy2-quic"
		out := map[string]any{"type": "hysteria2", "password": password, "fingerprint": pin}
		in := inbound.Hysteria2Option{BaseOption: base("hy2"), Certificate: cert, PrivateKey: private, Users: map[string]string{"fixture": password}}
		if obfs != "" {
			label += "-" + obfs
			in.Obfs, in.ObfsPassword = obfs, obfsPassword
			out["obfs"], out["obfs-password"] = obfs, obfsPassword
		}
		listener, err := inbound.NewHysteria2(&in)
		add(label, listener, err, out, true)
	}
	tuicIndex := len(nodes)
	for _, relay := range []string{"native", "quic"} {
		listener, err := inbound.NewTuic(&inbound.TuicOption{BaseOption: base("tuic"),
			Certificate: cert, PrivateKey: private, Users: map[string]string{account: password}})
		add("tuic-"+relay, listener, err, map[string]any{"type": "tuic", "uuid": account, "password": password,
			"fingerprint": pin, "udp-relay-mode": relay, "congestion-controller": "cubic"}, true)
	}
	forwardIndex := len(nodes)
	forwardUsers := inbound.AuthUsers{{Username: "fixture", Password: password}}
	for _, kind := range []string{"http", "socks5"} {
		for _, useTLS := range []bool{false, true} {
			label := kind + "-tcp"
			fields := map[string]any{"type": kind, "username": "fixture", "password": password, "tls": useTLS}
			var certificate, privateKey string
			if useTLS {
				label = kind + "-tls"
				certificate, privateKey = cert, private
				fields["fingerprint"] = pin
			}
			var listener C.InboundListener
			var err error
			if kind == "http" {
				listener, err = inbound.NewHTTP(&inbound.HTTPOption{BaseOption: base(kind), Users: forwardUsers,
					Certificate: certificate, PrivateKey: privateKey})
			} else {
				listener, err = inbound.NewSocks(&inbound.SocksOption{BaseOption: base(kind), Users: forwardUsers,
					Certificate: certificate, PrivateKey: privateKey})
			}
			add(label, listener, err, fields, false)
		}
	}

	data := normalizedFixtures(t, nodes...)
	for index, check := range variants {
		t.Run(check.label, func(t *testing.T) {
			// Alternate Rule and Global while choosing a different item from the
			// same imported list at each start. A different node cannot fake its marker.
			id, err := start(data, index+1, index%2)
			if err != nil {
				t.Fatal("engine rejected normalized multi-protocol profile")
			}
			defer stop(id)
			peer, ctx, closePeer := newPeer(t, id)
			defer closePeer()
			fetch(t, peer, ctx, tcpTarget, 18080, check.label)
			if check.udp {
				fetchUDP(t, peer, check.label)
			}
		})
	}
	t.Run("lab-live-switch-across-protocols", func(t *testing.T) {
		id, err := startLab(normalizedFixtures(t, nodes[0]), 0, demoEndpoint)
		if err != nil {
			t.Fatal("lab rejected first imported profile")
		}
		defer stop(id)
		peer, ctx, closePeer := newPeer(t, id)
		defer closePeer()
		for index, check := range variants {
			t.Run(check.label, func(t *testing.T) {
				if index > 0 && !replaceLab(id, normalizedFixtures(t, nodes[index]), index%2) {
					t.Fatal("lab rejected imported replacement")
				}
				fetch(t, peer, ctx, tcpTarget, int(demoEndpoint.Port()), check.label)
			})
		}
	})
	t.Run("lab-live-udp-across-protocols", func(t *testing.T) {
		target := netip.AddrPortFrom(udpTarget, 53)
		id, err := startLab(normalizedFixtures(t, nodes[0]), 0, target)
		if err != nil {
			t.Fatal("lab rejected first imported datagram profile")
		}
		defer stop(id)
		peer, _, closePeer := newPeer(t, id)
		defer closePeer()
		conn := dialLabUDP(t, peer, target)
		defer conn.Close()
		for index, check := range variants {
			if !check.udp {
				continue
			}
			t.Run(check.label, func(t *testing.T) {
				if index > 0 && !replaceLab(id, normalizedFixtures(t, nodes[index]), index%2) {
					t.Fatal("lab rejected datagram replacement")
				}
				exchangeLabUDP(t, conn, check.label)
			})
		}
	})
	for _, check := range []struct {
		label, key, value string
		index             int
	}{
		{"ss2022-wrong-user-key", "password", syntheticSSKey(32, 0xFA) + ":" + syntheticSSKey(32, 0xFC), ssIdentityIndex},
		{"trojan-untrusted-cert", "fingerprint", "", trojanIndex},
		{"trojan-wrong-pin", "fingerprint", strings.Repeat("00", 32), trojanIndex},
		{"trojan-wrong-password", "password", "different-fixture-password", trojanIndex},
		{"hy2-wrong-pin", "fingerprint", strings.Repeat("00", 32), hy2Index},
		{"tuic-untrusted-cert", "fingerprint", "", tuicIndex},
		{"tuic-wrong-pin", "fingerprint", strings.Repeat("00", 32), tuicIndex},
		{"tuic-wrong-password", "password", "different-fixture-password", tuicIndex},
		{"http-wrong-password", "password", "different-fixture-password", forwardIndex},
		{"https-untrusted-cert", "fingerprint", "", forwardIndex + 1},
		{"https-wrong-pin", "fingerprint", strings.Repeat("00", 32), forwardIndex + 1},
		{"socks5-wrong-password", "password", "different-fixture-password", forwardIndex + 2},
		{"socks5-tls-untrusted-cert", "fingerprint", "", forwardIndex + 3},
		{"socks5-tls-wrong-pin", "fingerprint", strings.Repeat("00", 32), forwardIndex + 3},
	} {
		t.Run(check.label, func(t *testing.T) {
			wrong := cloneFields(nodes[check.index])
			if check.value == "" {
				delete(wrong, check.key)
			} else {
				wrong[check.key] = check.value
			}
			id, err := start(normalizedFixtures(t, wrong), 1, 1)
			if err != nil {
				t.Fatal("expected a syntactically valid profile for handshake rejection")
			}
			defer stop(id)
			peer, ctx, closePeer := newPeer(t, id)
			defer closePeer()
			checkNoReply(t, peer, ctx)
		})
	}
}

func TestForwardProxyPrivateProfileRejectsUnsafeOptions(t *testing.T) {
	for _, changed := range []map[string]any{
		{"udp": true}, {"headers": map[string]any{"Host": "unused.invalid"}}, {"dialer-proxy": "external"},
		{"tls": true, "skip-cert-verify": true}, {"tls": false, "fingerprint": strings.Repeat("00", 32)},
		{"tls": true, "skip-cert-verify": false, "sni": "explicit.invalid"}, {"port": 42.5},
		{"username": "fixture"}, {"username": "fixture", "password": strings.Repeat("é", 128)},
	} {
		node := map[string]any{"name": "node-478733c8-afad-47f1-8ee0-cee758e7447f", "type": "socks5",
			"server": "127.0.0.1", "port": 1080, "tls": false}
		for key, value := range changed {
			node[key] = value
		}
		data, _ := json.Marshal(profile{Proxies: []map[string]any{node}, Rules: []string{"MATCH,CLAY"}})
		if _, _, err := decodeProfile(data); err == nil {
			t.Fatal("unsafe forwarding option passed the private ABI")
		}
	}
}

func TestShadowsocksRejectsUnsafePrivateProfile(t *testing.T) {
	key16 := syntheticSSKey(16, 0xFA)
	key32 := syntheticSSKey(32, 0xFA)
	for _, altered := range []map[string]any{
		{"password": "ordinary-password"}, {"password": key32}, {"password": key16[:len(key16)-1]},
		{"password": key16 + ":"}, {"password": strings.Repeat(key16+":", 32) + key16},
		{"password": key16[:len(key16)-3] + "B=="}, {"password": "\n" + key16},
		{"cipher": "2022-blake3-chacha20-poly1305", "password": key32 + ":" + key32},
		{"cipher": "none"}, {"plugin": "obfs"}, {"skip-cert-verify": true},
	} {
		node := map[string]any{"name": "node-478733c8-afad-47f1-8ee0-cee758e7447f", "type": "ss",
			"server": "127.0.0.1", "port": 443, "cipher": "2022-blake3-aes-128-gcm", "password": key16, "udp": true}
		for field, value := range altered {
			node[field] = value
		}
		data, _ := json.Marshal(profile{Proxies: []map[string]any{node}, Rules: []string{"MATCH,CLAY"}})
		if _, _, err := decodeProfile(data); err == nil {
			t.Fatal("invalid Shadowsocks profile passed the private ABI")
		}
	}
}

func TestLabTuicPacketLifetime(t *testing.T) {
	route, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := labPacketDialer{Dialer: dialer.NewDialer(), route: route}
	remote := netip.MustParseAddrPort("127.0.0.1:9") // The test does not send any packet.
	conn, err := d.ListenPacket(context.Background(), "udp", "127.0.0.1:0", remote)
	if err != nil {
		t.Fatal("unable to create loopback QUIC transport socket")
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	cancel()
	if _, _, err := conn.ReadFrom(make([]byte, 8)); !errors.Is(err, net.ErrClosed) {
		t.Fatal("retired lab route did not close its QUIC socket")
	}
	if stray, err := d.ListenPacket(context.Background(), "udp", "127.0.0.1:0", remote); !errors.Is(err, context.Canceled) {
		if stray != nil {
			_ = stray.Close()
		}
		t.Fatal("retired lab route can still open a new socket")
	}
}

func TestTuicRejectsUnsafePrivateProfile(t *testing.T) {
	for _, altered := range []map[string]any{
		{"skip-cert-verify": true}, {"disable-sni": true}, {"reduce-rtt": true}, {"token": "fixture"},
		{"certificate": "/tmp/unknown"}, {"udp-relay-mode": "invalid"}, {"alpn": []string{}},
		{"uuid": "invalid"}, {"password": ""}, {"fingerprint": "invalid"},
		{"type": "trojan"}, // TUIC options are not accepted on other node types.
	} {
		base := map[string]any{"name": "node-478733c8-afad-47f1-8ee0-cee758e7447f", "type": "tuic",
			"server": "127.0.0.1", "port": 443, "uuid": "478733c8-afad-47f1-8ee0-cee758e7447f", "password": "fixture",
			"skip-cert-verify": false, "alpn": []string{"h3"}, "udp-relay-mode": "native"}
		for key, value := range altered {
			base[key] = value
		}
		data, err := json.Marshal(profile{Proxies: []map[string]any{base}, Rules: []string{"MATCH,CLAY"}})
		if err != nil {
			t.Fatal("unable to encode fixture")
		}
		if _, _, err := decodeProfile(data); err != errProfile {
			t.Fatal("accepted unsafe or ambiguous TUIC options")
		}
	}
}

func checkNoReply(t *testing.T, peer *stack.Stack, ctx context.Context) {
	t.Helper()
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	conn, err := gonet.DialContextTCP(ctx, peer, tcpip.FullAddress{NIC: 1,
		Addr: tcpip.AddrFrom4(tcpTarget), Port: 18080}, header.IPv4ProtocolNumber)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(900 * time.Millisecond))
	if _, err := io.WriteString(conn, "synthetic-packet"); err != nil {
		return
	}
	if n, _ := conn.Read(make([]byte, 16)); n != 0 {
		t.Fatal("rejected handshake returned data")
	}
}
