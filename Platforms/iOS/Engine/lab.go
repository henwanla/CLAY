// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"net"
	"net/netip"
	"sync"
	"time"

	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing/common/buf"
	"github.com/metacubex/sing/common/bufio"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"

	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
)

const labProfileLimit = 128 * 1024
const labPort = 18080

var labOrigin = netip.MustParseAddr("198.18.0.1")
var labDestination = netip.MustParseAddr("198.51.100.42")

// The Lab admits a single fixed test flow destination. Rule mode has one rule
// for that destination; Global also uses the selected node. No Direct adapter,
// system DNS hook, controller, or global tunnel settings are installed here.
func parseLab(data []byte, mode int) (*labRoute, error) {
	if len(data) > labProfileLimit || (mode != 0 && mode != 1) {
		return nil, errProfile
	}
	p, _, err := decodeProfile(data)
	if err != nil || len(p.Proxies) != 1 || len(p.Rules) != 1 || p.Rules[0] != "MATCH,CLAY" {
		return nil, errProfile
	}
	proxy, err := adapter.ParseProxy(p.Proxies[0])
	if err != nil {
		return nil, errProfile
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &labRoute{proxy: proxy, ctx: ctx, cancel: cancel, flows: make(map[*labFlow]bool)}, nil
}

func startLab(data []byte, mode int) (uint64, error) {
	engine.Lock()
	defer engine.Unlock()
	if engine.live != nil {
		return 0, errActive
	}
	silence()
	route, err := parseLab(data, mode)
	if err != nil {
		return 0, err
	}
	lab := &labTunnel{route: route}
	live, err := makeSession(lab)
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
	route, err := parseLab(data, mode)
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
	mu    sync.Mutex
	route *labRoute
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
	if m.Source.Fqdn != "" || m.Source.Addr.Unmap() != labOrigin || m.Destination.Fqdn != "" ||
		m.Destination.Addr.Unmap() != labDestination || m.Destination.Port != labPort {
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
		SrcIP: labOrigin, SrcPort: m.Source.Port, DstIP: labDestination, DstPort: labPort})
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
