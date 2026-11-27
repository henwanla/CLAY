// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/adapters/gonet"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/network/ipv4"
	"github.com/metacubex/gvisor/pkg/tcpip/network/ipv6"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	"github.com/metacubex/gvisor/pkg/tcpip/transport/tcp"
	"github.com/metacubex/gvisor/pkg/tcpip/transport/udp"
	"github.com/metacubex/mihomo/tunnel"
)

func syntheticNodes(first, second int) []byte {
	data, _ := json.Marshal(profile{
		Proxies: []map[string]any{
			{"name": "node-11111111-1111-4111-8111-111111111111", "type": "vless", "server": "127.0.0.1", "port": first,
				"uuid": "56dc6c3e-8793-4d37-a363-f9f19db29c6d", "network": "tcp", "udp": true},
			{"name": "node-22222222-2222-4222-8222-222222222222", "type": "vless", "server": "127.0.0.1", "port": second,
				"uuid": "56dc6c3e-8793-4d37-a363-f9f19db29c6d", "network": "tcp", "udp": true},
		},
		Rules: []string{"IP-CIDR,198.51.100.42/32,CLAY,no-resolve", "MATCH,DIRECT"},
	})
	return data
}

func proxyFixture(t *testing.T, reply string, disconnectChecks ...chan error) int {
	t.Helper()
	return proxyFixtureFor(t, reply, demoEndpoint, nil, disconnectChecks...)
}

func proxyFixtureFor(t *testing.T, reply string, endpoint netip.AddrPort, accepted *atomic.Uint64, disconnectChecks ...chan error) int {
	t.Helper()
	ln, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.AcceptTCP()
			if err != nil {
				return
			}
			if accepted != nil {
				accepted.Add(1)
			}
			func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
				prefix, _ := hex.DecodeString("0056dc6c3e87934d37a363f9f19db29c6d00")
				data := make([]byte, len(prefix)+1)
				if _, err := io.ReadFull(conn, data); err != nil || !bytes.Equal(data[:len(prefix)], prefix) {
					return
				}
				if data[len(prefix)] == 3 {
					respondUDP(conn, reply)
					return
				}
				if data[len(prefix)] != 1 {
					return
				}
				kind := byte(1)
				if endpoint.Addr().Is6() {
					kind = 3
				}
				target := append(binary.BigEndian.AppendUint16(nil, endpoint.Port()), kind)
				target = append(target, endpoint.Addr().AsSlice()...)
				data = make([]byte, len(target))
				if _, err := io.ReadFull(conn, data); err != nil || !bytes.Equal(data, target) {
					return
				}
				if _, err := conn.Write([]byte{0, 0}); err != nil {
					return
				}
				received := make([]byte, len("synthetic-packet"))
				if _, err := io.ReadFull(conn, received); err == nil && string(received) == "synthetic-packet" {
					if _, err := conn.Write([]byte(reply)); err == nil && len(disconnectChecks) == 1 {
						_, err = conn.Read(make([]byte, 1))
						disconnectChecks[0] <- err
					}
				}
			}()
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

// VLESS XUDP fixture: answers only a single synthetic payload to the reserved
// IPv4 address and port. It never forwards traffic to a network destination.
func respondUDP(conn net.Conn, reply string) {
	target, _ := hex.DecodeString("02003501c6336435")
	read := func(size int) []byte {
		data := make([]byte, size)
		if _, err := io.ReadFull(conn, data); err != nil {
			return nil
		}
		return data
	}
	length := read(2)
	if length == nil {
		return
	}
	n := binary.BigEndian.Uint16(length)
	if n != 12 && n != 20 {
		return
	}
	frame := read(int(n))
	if frame == nil || !bytes.Equal(frame[:12], append([]byte{0, 0, 1, 1}, target...)) {
		return
	}
	length = read(2)
	if length == nil || int(binary.BigEndian.Uint16(length)) != len("packet-proof") ||
		string(read(len("packet-proof"))) != "packet-proof" {
		return
	}
	wire := append([]byte{0, 0, 0, 12, 0, 0, 2, 1}, target...)
	wire = append(wire, 0, byte(len(reply)))
	_, _ = conn.Write(append(wire, reply...))
}

func newPeer(t *testing.T, id uint64) (*stack.Stack, context.Context, func()) {
	return newPeerFor(t, id, labNetwork4)
}

func newPeerFor(t *testing.T, id uint64, network netip.Prefix) (*stack.Stack, context.Context, func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	local := channel.New(64, mtu, "")
	networkFactory, family, subnet := ipv4.NewProtocol, header.IPv4ProtocolNumber, header.IPv4EmptySubnet
	if network.Addr().Is6() {
		networkFactory, family, subnet = ipv6.NewProtocol, header.IPv6ProtocolNumber, header.IPv6EmptySubnet
	}
	peer := stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{networkFactory},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol}})
	if err := peer.CreateNIC(1, local); err != nil {
		t.Fatal(err)
	}
	addr := tcpip.AddrFromSlice(network.Addr().AsSlice())
	if err := peer.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: family,
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: addr, PrefixLen: network.Bits()}}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	peer.SetRouteTable([]tcpip.Route{{Destination: subnet, NIC: 1}})
	done1, done2 := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done1)
		for {
			pkt := local.ReadContext(ctx)
			if pkt == nil {
				return
			}
			v := pkt.ToView()
			pkt.DecRef()
			offer(id, v.AsSlice())
			v.Release()
		}
	}()
	go func() {
		defer close(done2)
		out := make([]byte, mtu)
		for ctx.Err() == nil {
			n := receive(id, out, 40*time.Millisecond)
			if n <= 0 {
				continue
			}
			pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(bytes.Clone(out[:n]))})
			local.InjectInbound(family, pkt)
			pkt.DecRef()
		}
	}()
	return peer, ctx, func() {
		cancel()
		// Close both packet queues before joining the workers. A receive may
		// already be waiting on the engine session's context, not the peer's.
		local.Close()
		stop(id)
		<-done1
		<-done2
		peer.Close()
	}
}

func fetch(t *testing.T, peer *stack.Stack, ctx context.Context, dest [4]byte, port int, want string) {
	t.Helper()
	fetchTarget(t, peer, ctx, netip.AddrPortFrom(netip.AddrFrom4(dest), uint16(port)), want)
}

func dialTarget(ctx context.Context, peer *stack.Stack, target netip.AddrPort) (*gonet.TCPConn, error) {
	family := header.IPv4ProtocolNumber
	if target.Addr().Is6() {
		family = header.IPv6ProtocolNumber
	}
	return gonet.DialContextTCP(ctx, peer, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(target.Addr().AsSlice()), Port: target.Port()}, family)
}

func fetchTarget(t *testing.T, peer *stack.Stack, ctx context.Context, target netip.AddrPort, want string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	conn, err := dialTarget(ctx, peer, target)
	if err != nil {
		t.Fatalf("dial synthetic TCP target port %d: %v", target.Port(), err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.WriteString(conn, "synthetic-packet"); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, len(want))
	if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != want {
		t.Fatalf("did not receive expected marker: %v", err)
	}
}

func fetchUDP(t *testing.T, peer *stack.Stack, want string) {
	t.Helper()
	target := tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{198, 51, 100, 53}), Port: 53}
	conn, err := gonet.DialUDP(peer, nil, &target, header.IPv4ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.WriteString(conn, "packet-proof"); err != nil {
		t.Fatal(err)
	}
	out := make([]byte, mtu)
	n, err := conn.Read(out)
	if err != nil || string(out[:n]) != want {
		t.Fatalf("UDP through VLESS did not return expected marker: %v", err)
	}
}

func TestModesAndRestart(t *testing.T) {
	a := proxyFixture(t, "via-one")
	b := proxyFixture(t, "via-two")
	input := syntheticNodes(a, b)
	var last uint64
	for _, test := range []struct {
		node, mode int
		expected   tunnel.TunnelMode
		want       string
	}{
		{1, 1, tunnel.Global, "via-one"}, {2, 1, tunnel.Global, "via-two"},
		{2, 0, tunnel.Rule, "via-two"}, {1, 2, tunnel.Direct, ""},
	} {
		id, err := start(input, test.node, test.mode)
		if err != nil {
			t.Fatal(err)
		}
		func() {
			defer stop(id)
			if id == 0 || id == last || tunnel.Mode() != test.expected {
				t.Fatal("session or mode not applied")
			}
			if last != 0 {
				stop(last)
				if receive(last, make([]byte, mtu), time.Millisecond) != inactive {
					t.Fatal("stale session received data")
				}
			}
			last = id
			if test.mode == 2 {
				return
			} // No direct real network traffic in this fixture.
			peer, ctx, closePeer := newPeer(t, id)
			defer closePeer()
			fetch(t, peer, ctx, [4]byte{198, 51, 100, 42}, 18080, test.want)
			if test.mode == 1 {
				fetchUDP(t, peer, test.want)
			}
		}()
	}
}

func TestStopClosesActiveTCP(t *testing.T) {
	checkFlowRetirement(t, false, demoEndpoint)
}

func TestLabSwitchClosesActiveTCP(t *testing.T) {
	checkFlowRetirement(t, true, netip.MustParseAddrPort("203.0.113.37:40443"))
}

func TestLabIPv6SwitchClosesActiveTCP(t *testing.T) {
	checkFlowRetirement(t, true, netip.MustParseAddrPort("[2001:db8::37]:40443"))
}

func checkFlowRetirement(t *testing.T, switchRoute bool, target netip.AddrPort) {
	t.Helper()
	disconnected := make(chan error, 1)
	var accepted atomic.Uint64
	port := proxyFixtureFor(t, "open", target, &accepted, disconnected)
	var id uint64
	var err error
	if switchRoute {
		id, err = startLab(labFixture(t, port), 0, target)
	} else {
		id, err = start(syntheticNodes(port, port), 1, 1)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer stop(id)
	network, alternate := labNetwork4, demoEndpoint.Addr()
	foreignHeader := make([]byte, header.IPv6MinimumSize)
	foreignHeader[0] = 0x60
	if target.Addr().Is6() {
		network, alternate = labNetwork6, netip.MustParseAddr("2001:db8::42")
		foreignHeader = make([]byte, header.IPv4MinimumSize)
		foreignHeader[0], foreignHeader[3] = 0x45, header.IPv4MinimumSize
	}
	if protocol(foreignHeader) == 0 || offer(id, foreignHeader) {
		t.Fatal("session accepted a packet outside its address family")
	}
	peer, ctx, closePeer := newPeerFor(t, id, network)
	defer closePeer()
	if switchRoute {
		for _, forbidden := range []netip.AddrPort{
			netip.AddrPortFrom(alternate, target.Port()),
			netip.AddrPortFrom(target.Addr(), demoEndpoint.Port()),
		} {
			assertLabRejects(t, peer, ctx, forbidden)
		}
		if accepted.Load() != 0 {
			t.Fatal("an out-of-scope connection reached the proxy")
		}
	}
	dialCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	conn, err := dialTarget(dialCtx, peer, target)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.WriteString(conn, "synthetic-packet"); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, len("open"))
	if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != "open" {
		t.Fatal("fixture did not open the routed connection")
	}
	if switchRoute {
		replacement := labFixture(t, proxyFixtureFor(t, "via-next", target, nil))
		selfRoute := normalizedFixtures(t, map[string]any{"name": "lab", "type": "vless", "server": target.Addr().String(), "port": port,
			"uuid": "56dc6c3e-8793-4d37-a363-f9f19db29c6d"})
		if replaceLab(id+1, replacement, 1) || replaceLab(id, replacement, 2) ||
			replaceLab(id, syntheticNodes(port, port), 0) || replaceLab(id, []byte("invalid"), 1) || replaceLab(id, selfRoute, 1) {
			t.Fatal("invalid update was accepted")
		}
		select {
		case <-disconnected:
			t.Fatal("a rejected update closed the active connection")
		default:
		}
		if !replaceLab(id, replacement, 1) {
			t.Fatal("lab refused a valid replacement")
		}
	} else {
		stop(id)
	}
	select {
	case err := <-disconnected:
		if err == nil {
			t.Fatal("unexpected payload after stopping")
		}
		if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
			t.Fatal("fixture timed out before the old connection closed")
		}
	case <-time.After(time.Second):
		t.Fatal("old fixture connection did not close")
	}
	if switchRoute {
		// Keep the same peer, stack, and session. The new flow must receive the
		// new upstream's marker, even while the old TCP socket is still open here.
		fetchTarget(t, peer, ctx, target, "via-next")
	}
}

func assertLabRejects(t *testing.T, peer *stack.Stack, ctx context.Context, target netip.AddrPort) {
	t.Helper()
	dialCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	conn, err := dialTarget(dialCtx, peer, target)
	if err == nil {
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err = io.WriteString(conn, "synthetic-packet"); err == nil {
			_, err = conn.Read(make([]byte, 1))
		}
	}
	if timeout, ok := err.(net.Error); err == nil || (ok && timeout.Timeout()) || dialCtx.Err() != nil {
		t.Fatal("out-of-scope connection was not closed")
	}
}

func TestLabTargetScope(t *testing.T) {
	for _, example := range []struct {
		endpoint string
		valid    bool
	}{
		{"198.51.100.42:18080", true}, {"10.20.30.40:65535", true},
		{"0.1.2.3:80", false}, {"127.0.0.1:80", false}, {"169.254.1.1:80", false},
		{"198.18.0.1:80", false}, {"198.18.0.2:80", false}, {"198.18.0.3:80", false}, {"224.0.0.1:80", false},
		{"240.1.2.3:80", false}, {"203.0.113.37:0", false}, {"[2001:db8::1]:80", true}, {"[fd00::7]:443", true},
		{"[::ffff:203.0.113.37]:80", false}, {"[::203.0.113.37]:80", false}, {"[::1]:80", false}, {"[::]:80", false},
		{"[fe80::1]:80", false}, {"[ff02::1]:80", false}, {"[2001:db8::1%en0]:80", false}, {"[fdfe:dcba:9876::3]:80", false},
	} {
		if got := validLabTarget(netip.MustParseAddrPort(example.endpoint)); got != example.valid {
			t.Errorf("validLabTarget(%q) = %t, want %t", example.endpoint, got, example.valid)
		}
	}
}

func labFixture(t *testing.T, port int) []byte {
	t.Helper()
	return normalizedFixtures(t, map[string]any{"name": "lab", "type": "vless", "server": "127.0.0.1", "port": port,
		"uuid": "56dc6c3e-8793-4d37-a363-f9f19db29c6d"})
}

func TestClosedAndRejectsUnsupportedInput(t *testing.T) {
	if receive(1, make([]byte, mtu), time.Millisecond) != inactive {
		t.Fatal("inactive engine readable")
	}
	if offer(1, make([]byte, 40)) {
		t.Fatal("inactive engine accepted packet")
	}
	if id, err := start([]byte(`{"proxies":[],"rules":["MATCH,DIRECT"],"external-controller":"0.0.0.0:9090"}`), 1, 1); err == nil {
		stop(id)
		t.Fatal("config accepted an unsupported listener field")
	}
	var p profile
	if err := json.Unmarshal(syntheticNodes(443, 443), &p); err != nil {
		t.Fatal(err)
	}
	p.Proxies[0]["ws-opts"] = map[string]any{"headers": map[string]any{"Authorization": "example"}}
	data, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	if id, err := start(data, 1, 1); err == nil {
		stop(id)
		t.Fatal("config accepted an unsupported WebSocket header")
	}
	badIPv6 := make([]byte, 60)
	badIPv6[0], badIPv6[5] = 0x60, 21
	if protocol(badIPv6) != 0 {
		t.Fatal("IPv6 header accepted the wrong payload length")
	}
}
