// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
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
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
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
		addr, err := netip.ParseAddrPort(listener.Address())
		if err != nil || addr.Addr() != netip.MustParseAddr("127.0.0.1") || addr.Port() == 0 {
			t.Fatalf("%s expected a unique IPv4 loopback listener", label)
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
	trojan, err := inbound.NewTrojan(&inbound.TrojanOption{BaseOption: base("trojan"),
		Certificate: cert, PrivateKey: private, Users: []inbound.TrojanUser{{Username: "fixture", Password: password}}})
	add("trojan-tls", trojan, err, map[string]any{"type": "trojan", "password": password, "fingerprint": pin, "udp": true}, true)
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
	for _, check := range []struct {
		label, key, value string
		index             int
	}{
		{"trojan-untrusted-cert", "fingerprint", "", 3},
		{"trojan-wrong-pin", "fingerprint", strings.Repeat("00", 32), 3},
		{"trojan-wrong-password", "password", "different-fixture-password", 3},
		{"hy2-wrong-pin", "fingerprint", strings.Repeat("00", 32), 4},
		{"tuic-untrusted-cert", "fingerprint", "", tuicIndex},
		{"tuic-wrong-pin", "fingerprint", strings.Repeat("00", 32), tuicIndex},
		{"tuic-wrong-password", "password", "different-fixture-password", tuicIndex},
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
