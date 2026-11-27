// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/metacubex/gvisor/pkg/tcpip/header"
	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing/common/buf"
	"github.com/metacubex/sing/common/bufio"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/dialer"
	C "github.com/metacubex/mihomo/constant"
)

const labProfileLimit = 128 * 1024

var labNetwork4 = netip.MustParsePrefix("198.18.0.1/30")
var labNetwork6 = netip.MustParsePrefix("fdfe:dcba:9876::1/126")
var compatibleIPv4 = netip.MustParsePrefix("::/96")

func validLabTarget(target netip.AddrPort) bool {
	ip := target.Addr()
	if target.Port() == 0 || ip.Zone() != "" || !ip.IsGlobalUnicast() {
		return false
	}
	if ip.Is4() {
		return !labNetwork4.Contains(ip) && ip.As4()[0] != 0 && ip.As4()[0] < 224
	}
	return !ip.Is4In6() && !compatibleIPv4.Contains(ip) && !labNetwork6.Contains(ip)
}

// One scoped TCP endpoint is routed through the selected node in either mode.
// A node replacement cannot change that endpoint or send it directly.
func parseLab(data []byte, mode int, target netip.AddrPort) (*labRoute, error) {
	if len(data) > labProfileLimit || (mode != 0 && mode != 1) {
		return nil, errProfile
	}
	p, _, err := decodeProfile(data)
	if err != nil || len(p.Proxies) != 1 || len(p.Rules) != 1 || p.Rules[0] != "MATCH,CLAY" {
		return nil, errProfile
	}
	server, _ := p.Proxies[0]["server"].(string)
	if address, err := netip.ParseAddr(server); err == nil && address.Unmap() == target.Addr() {
		return nil, errProfile
	}
	ctx, cancel := context.WithCancel(context.Background())
	var options []adapter.ProxyOption
	if p.Proxies[0]["type"] == "tuic" {
		// The pinned adapter's Close does not retire pooled QUIC connections.
		// Tie their underlying sockets to this route, including pending handshakes.
		options = append(options, adapter.WithDialerForAPI(labPacketDialer{Dialer: dialer.NewDialer(), route: ctx}))
	}
	proxy, err := adapter.ParseProxy(p.Proxies[0], options...)
	if err != nil {
		cancel()
		return nil, errProfile
	}
	return &labRoute{proxy: proxy, ctx: ctx, cancel: cancel, flows: make(map[*labFlow]bool)}, nil
}

type labPacketDialer struct {
	C.Dialer
	route context.Context
}

func (d labPacketDialer) ListenPacket(ctx context.Context, network, address string, remote netip.AddrPort) (net.PacketConn, error) {
	if err := d.route.Err(); err != nil {
		return nil, err
	}
	socket, err := d.Dialer.ListenPacket(ctx, network, address, remote)
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(d.route, func() { _ = socket.Close() })
	conn := &labPacketConn{PacketConn: socket, stop: stop}
	if err := d.route.Err(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

type labPacketConn struct {
	net.PacketConn
	stop func() bool
}

func (c *labPacketConn) Close() error {
	c.stop()
	return c.PacketConn.Close()
}

func startLab(data []byte, mode int, target netip.AddrPort) (uint64, error) {
	engine.Lock()
	defer engine.Unlock()
	if engine.live != nil {
		return 0, errActive
	}
	if !validLabTarget(target) {
		return 0, errProfile
	}
	route, err := parseLab(data, mode, target)
	if err != nil {
		return 0, err
	}
	network, family := labNetwork4, header.IPv4ProtocolNumber
	if target.Addr().Is6() {
		network, family = labNetwork6, header.IPv6ProtocolNumber
	}
	lab := &labTunnel{route: route, target: target, origin: network.Addr()}
	live, err := makeSession(lab, family)
	if err != nil {
		lab.install(nil)
		return 0, err
	}
	live.lab = lab
	return publishSession(live), nil
}

func replaceLab(id uint64, data []byte, mode int) bool {
	engine.Lock()
	defer engine.Unlock()
	live := engine.live
	if live == nil || live.id != id || live.lab == nil {
		return false
	}
	route, err := parseLab(data, mode, live.lab.target)
	if err != nil {
		return false
	}
	live.lab.install(route)
	return true
}

type labRoute struct {
	proxy  C.Proxy
	ctx    context.Context
	cancel context.CancelFunc
	flows  map[*labFlow]bool // guarded by labTunnel.mu
	users  sync.WaitGroup
}

type labFlow struct {
	local  net.Conn
	remote net.Conn // assigned under labTunnel.mu
}

type labTunnel struct {
	mu     sync.Mutex
	route  *labRoute
	target netip.AddrPort // immutable for the lifetime of the tunnel
	origin netip.Addr
}

func (lab *labTunnel) install(route *labRoute) {
	lab.mu.Lock()
	old := lab.route
	lab.route = route
	var sockets []net.Conn
	if old != nil {
		for flow := range old.flows {
			sockets = append(sockets, flow.local)
			if flow.remote != nil {
				sockets = append(sockets, flow.remote)
			}
		}
	}
	lab.mu.Unlock()
	if old == nil {
		return
	}
	old.cancel()
	for _, conn := range sockets {
		_ = conn.Close()
	}
	// Do not block the control queue on a protocol-specific dial/teardown.
	// No new flow can take a reference to old after the swap.
	go func() { old.users.Wait(); _ = old.proxy.Close() }()
}

func (lab *labTunnel) NewConnection(_ context.Context, conn net.Conn, m M.Metadata) error {
	defer conn.Close()
	if m.Source.Fqdn != "" || m.Source.Addr.Unmap() != lab.origin || m.Destination.Fqdn != "" ||
		m.Destination.Addr.Unmap() != lab.target.Addr() || m.Destination.Port != lab.target.Port() {
		return nil
	}
	lab.mu.Lock()
	route := lab.route
	if route == nil {
		lab.mu.Unlock()
		return nil
	}
	flow := &labFlow{local: conn}
	route.flows[flow] = true
	route.users.Add(1)
	lab.mu.Unlock()
	defer func() {
		lab.mu.Lock()
		delete(route.flows, flow)
		lab.mu.Unlock()
		route.users.Done()
	}()

	ctx, cancel := context.WithTimeout(route.ctx, C.DefaultTCPTimeout)
	remote, err := route.proxy.DialContext(ctx, &C.Metadata{NetWork: C.TCP, Type: C.TUN,
		SrcIP: lab.origin, SrcPort: m.Source.Port, DstIP: lab.target.Addr(), DstPort: lab.target.Port()})
	cancel()
	if err != nil {
		return nil
	} // A dial error can contain credentials; never log it.
	defer remote.Close()
	lab.mu.Lock()
	if lab.route != route {
		lab.mu.Unlock()
		return nil
	}
	flow.remote = remote
	lab.mu.Unlock()
	_ = bufio.CopyConn(route.ctx, conn, remote)
	return nil
}

func (*labTunnel) PrepareConnection(string, M.Socksaddr, M.Socksaddr, tun.DirectRouteContext, time.Duration) (tun.DirectRouteDestination, error) {
	return nil, tun.ErrDrop
}
func (*labTunnel) NewPacket(_ context.Context, _ netip.AddrPort, data *buf.Buffer, _ M.Metadata, _ func(N.PacketConn) N.PacketWriter) {
	data.Release()
}
func (*labTunnel) NewError(context.Context, error) {}
