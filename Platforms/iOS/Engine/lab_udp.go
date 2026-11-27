// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"context"
	"net"
	"net/netip"
	"time"

	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"

	C "github.com/metacubex/mihomo/constant"
)

const (
	labUDPAssociations = 32
	labUDPQueue        = 8
	labUDPIdle         = 30 * time.Second
)

type labDatagrams struct {
	pending chan []byte
	writer  N.PacketWriter
	remote  net.PacketConn // guarded by labTunnel.mu
}

func (lab *labTunnel) udpPayloadLimit() int {
	if lab.target.Addr().Is6() {
		return mtu - 40 - 8
	}
	return mtu - 20 - 8
}

func (lab *labTunnel) NewPacket(_ context.Context, key netip.AddrPort, data *buf.Buffer, m M.Metadata,
	init func(N.PacketConn) N.PacketWriter) {
	defer data.Release()
	if !lab.inScope(m) || key != m.Source.AddrPort() || data.Len() > lab.udpPayloadLimit() {
		return
	}
	port := m.Source.Port
	lab.mu.Lock()
	defer lab.mu.Unlock()
	route := lab.route
	if route == nil || !route.proxy.SupportUDP() {
		return // UDP cannot bypass the selected node.
	}
	flow := route.datagrams[port]
	if flow == nil {
		if len(route.datagrams) >= labUDPAssociations {
			return
		}
		flow = &labDatagrams{pending: make(chan []byte, labUDPQueue), writer: init(nil)}
		route.datagrams[port] = flow
		route.users.Add(1)
		go lab.relayUDP(route, flow, port)
	}
	// The packet callback must not stall the packet stack behind a slow proxy.
	if len(flow.pending) < cap(flow.pending) {
		flow.pending <- bytes.Clone(data.Bytes())
	}
}

func (lab *labTunnel) relayUDP(route *labRoute, flow *labDatagrams, port uint16) {
	defer func() {
		lab.mu.Lock()
		delete(route.datagrams, port)
		lab.mu.Unlock()
		route.users.Done()
	}()
	dial, cancelDial := context.WithTimeout(route.ctx, C.DefaultUDPTimeout)
	remote, err := route.proxy.ListenPacketContext(dial, &C.Metadata{NetWork: C.UDP, Type: C.TUN,
		SrcIP: lab.origin, SrcPort: port, DstIP: lab.target.Addr(), DstPort: lab.target.Port()})
	cancelDial()
	if err != nil {
		return
	}
	defer remote.Close()
	lab.mu.Lock()
	if lab.route != route {
		lab.mu.Unlock()
		return
	}
	flow.remote = remote
	lab.mu.Unlock()

	ctx, cancel := context.WithCancel(route.ctx)
	destination := net.UDPAddrFromAddrPort(lab.target)
	limit := lab.udpPayloadLimit()
	_ = remote.SetReadDeadline(time.Now().Add(labUDPIdle))
	written := make(chan struct{})
	go func() {
		defer close(written)
		defer remote.Close()
		for {
			select {
			case <-ctx.Done():
				return
			case payload := <-flow.pending:
				if ctx.Err() != nil {
					return
				}
				_ = remote.SetWriteDeadline(time.Now().Add(C.DefaultUDPTimeout))
				if _, err := remote.WriteTo(payload, destination); err != nil {
					return
				}
				_ = remote.SetReadDeadline(time.Now().Add(labUDPIdle))
			}
		}
	}()
	defer func() { cancel(); _ = remote.Close(); <-written }()
	// Extra byte makes a truncated oversized packet distinguishable from an
	// exact-size reply. Only the pinned source can be injected into the device.
	response := make([]byte, limit+1)
	for {
		n, peer, err := remote.ReadFrom(response)
		if err != nil || ctx.Err() != nil {
			return
		}
		from, ok := peer.(*net.UDPAddr)
		if !ok || from == nil || from.AddrPort().Addr().Unmap() != lab.target.Addr() ||
			from.AddrPort().Port() != lab.target.Port() || n > limit {
			continue
		}
		_ = remote.SetReadDeadline(time.Now().Add(labUDPIdle))
		lab.mu.Lock()
		active := lab.route == route
		lab.mu.Unlock()
		if !active || flow.writer.WritePacket(buf.As(response[:n]), M.SocksaddrFromNetIP(lab.target)) != nil {
			return
		}
	}
}
