// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	glog "github.com/metacubex/gvisor/pkg/log"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	tun "github.com/metacubex/sing-tun"
	M "github.com/metacubex/sing/common/metadata"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const mtu = 1500
const maxProfileBytes = 2 * 1024 * 1024
const maxNodes = 100
const inactive = -1

var nodeName = regexp.MustCompile("^node-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
var tuicAccount = regexp.MustCompile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
var certificateDigest = regexp.MustCompile("^[0-9a-f]{64}$")
var errProfile = errors.New("invalid packet profile")
var errActive = errors.New("session already running")

var nodeKeys = map[string]bool{
	"name": true, "type": true, "server": true, "port": true, "uuid": true, "network": true, "udp": true,
	"packet-encoding": true, "cipher": true, "alterId": true, "flow": true, "tls": true, "skip-cert-verify": true,
	"servername": true, "client-fingerprint": true, "alpn": true, "reality-opts": true, "ws-opts": true, "grpc-opts": true,
	"password": true, "sni": true, "obfs": true, "obfs-password": true, "fingerprint": true,
}

var nestedKeys = map[string]map[string]bool{
	"reality-opts": {"public-key": true, "short-id": true, "support-x25519mlkem768": true},
	"ws-opts":      {"path": true, "headers": true},
	"grpc-opts":    {"grpc-service-name": true},
}

var tuicKeys = map[string]bool{
	"name": true, "type": true, "server": true, "port": true, "uuid": true, "password": true,
	"sni": true, "alpn": true, "skip-cert-verify": true, "fingerprint": true,
	"udp-relay-mode": true, "congestion-controller": true,
}

var shadowsocksKeys = map[string]bool{
	"name": true, "type": true, "server": true, "port": true, "password": true, "cipher": true, "udp": true,
}

type profile struct {
	Proxies []map[string]any `json:"proxies"`
	Rules   []string         `json:"rules"`
}

// An upper layer converts user profiles into this private representation with CLAYCore.
// No raw provider YAML, controller, listener, paths or remote lists reach the engine.
func decodeProfile(data []byte) (profile, []string, error) {
	if len(data) == 0 || len(data) > maxProfileBytes {
		return profile{}, nil, errProfile
	}
	var p profile
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if d.Decode(&p) != nil || d.Decode(new(any)) != io.EOF || len(p.Proxies) == 0 ||
		len(p.Proxies) > maxNodes || len(p.Rules) == 0 || len(p.Rules) > 1024 {
		return profile{}, nil, errProfile
	}
	for i, line := range p.Rules {
		if !validRule(line, i == len(p.Rules)-1) {
			return profile{}, nil, errProfile
		}
	}
	ids := make([]string, len(p.Proxies))
	seen := make(map[string]bool, len(ids))
	for index, proxy := range p.Proxies {
		allowedKeys := nodeKeys
		switch proxy["type"] {
		case "tuic":
			allowedKeys = tuicKeys
			if !validTuic(proxy) {
				return profile{}, nil, errProfile
			}
		case "ss":
			allowedKeys = shadowsocksKeys
			if !validShadowsocks(proxy) {
				return profile{}, nil, errProfile
			}
		}
		for key, value := range proxy {
			if !allowedKeys[key] {
				return profile{}, nil, errProfile
			}
			if allowed, nested := nestedKeys[key]; nested {
				fields, ok := value.(map[string]any)
				if !ok {
					return profile{}, nil, errProfile
				}
				for field, value := range fields {
					if !allowed[field] {
						return profile{}, nil, errProfile
					}
					if field == "headers" {
						headers, ok := value.(map[string]any)
						if _, host := headers["Host"].(string); !ok || len(headers) != 1 || !host {
							return profile{}, nil, errProfile
						}
					}
				}
			}
		}
		id, _ := proxy["name"].(string)
		if !nodeName.MatchString(id) || seen[id] {
			return profile{}, nil, errProfile
		}
		seen[id] = true
		switch proxy["type"] {
		case "vmess", "vless", "ss", "trojan", "hysteria2", "tuic":
		default:
			return profile{}, nil, errProfile
		}
		ids[index] = id
	}
	return p, ids, nil
}

func validShadowsocks(node map[string]any) bool {
	password, ok := node["password"].(string)
	if !ok || password == "" || strings.IndexFunc(password, func(c rune) bool { return c < 32 || c == 127 }) >= 0 {
		return false
	}
	var keyBytes, maximumKeys int
	switch node["cipher"] {
	case "2022-blake3-aes-128-gcm":
		keyBytes, maximumKeys = 16, 32
	case "2022-blake3-aes-256-gcm":
		keyBytes, maximumKeys = 32, 32
	case "2022-blake3-chacha20-poly1305":
		keyBytes, maximumKeys = 32, 1
	case "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305":
		return true
	default:
		return false
	}
	encodedBytes := base64.StdEncoding.EncodedLen(keyBytes)
	if len(password) > maximumKeys*(encodedBytes+1)-1 {
		return false
	}
	for _, part := range strings.Split(password, ":") {
		if len(part) != encodedBytes {
			return false
		}
		decoded, err := base64.StdEncoding.Strict().DecodeString(part)
		if err != nil || len(decoded) != keyBytes {
			return false
		}
	}
	return true
}

func validTuic(node map[string]any) bool {
	account, _ := node["uuid"].(string)
	password, _ := node["password"].(string)
	if !tuicAccount.MatchString(account) || password == "" || strings.IndexFunc(password, func(c rune) bool { return c < 32 || c == 127 }) >= 0 ||
		node["skip-cert-verify"] != false || (node["udp-relay-mode"] != "native" && node["udp-relay-mode"] != "quic") {
		return false
	}
	if congestion, ok := node["congestion-controller"]; ok && congestion != "cubic" && congestion != "new_reno" && congestion != "bbr" {
		return false
	}
	if value, ok := node["sni"]; ok {
		if sni, isString := value.(string); !isString || sni == "" {
			return false
		}
	}
	if value, ok := node["fingerprint"]; ok {
		if pin, isString := value.(string); !isString || !certificateDigest.MatchString(pin) {
			return false
		}
	}
	alpn, ok := node["alpn"].([]any)
	if !ok || len(alpn) == 0 {
		return false
	}
	length := 0
	for _, value := range alpn {
		protocol, _ := value.(string)
		length += 1 + len(protocol)
		if len(protocol) == 0 || len(protocol) > 255 || length > 65535 ||
			strings.IndexFunc(protocol, func(c rune) bool { return c < 33 || c > 126 }) >= 0 {
			return false
		}
	}
	return true
}

func loadProfile(data []byte, chosen, mode int) (*config.Config, error) {
	p, ids, err := decodeProfile(data)
	if err != nil || chosen < 1 || chosen > len(ids) {
		return nil, errProfile
	}
	var useMode tunnel.TunnelMode
	switch mode {
	case 0:
		useMode = tunnel.Rule
	case 1:
		useMode = tunnel.Global
	case 2:
		useMode = tunnel.Direct
	default:
		return nil, errProfile
	}
	ordered := append([]string{ids[chosen-1]}, ids[:chosen-1]...)
	ordered = append(ordered, ids[chosen:]...)
	raw := config.DefaultRawConfig()
	raw.Mode, raw.LogLevel, raw.IPv6, raw.BindAddress = useMode, log.SILENT, false, "127.0.0.1"
	raw.FindProcessMode = process.FindProcessOff
	raw.Profile.StoreSelected, raw.GeoAutoUpdate = false, false
	raw.Proxy, raw.Rule = p.Proxies, p.Rules
	raw.ProxyGroup = []map[string]any{
		{"name": "CLAY", "type": "select", "proxies": ordered},
		{"name": "GLOBAL", "type": "select", "proxies": []string{"CLAY"}},
	}
	return config.ParseRawConfig(raw)
}

func validRule(line string, last bool) bool {
	parts := strings.Split(line, ",")
	if last {
		return len(parts) == 2 && parts[0] == "MATCH" && validAction(parts[1])
	}
	if len(parts) < 3 || !validAction(parts[2]) || len(parts[1]) == 0 {
		return false
	}
	switch parts[0] {
	case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
		return len(parts) == 3
	case "DOMAIN-REGEX":
		return len(parts) == 3 && parts[1] == "^[^.]+$" // Shared PAC local-name rule only.
	case "IP-CIDR", "IP-CIDR6":
		return len(parts) == 4 && parts[3] == "no-resolve"
	default:
		return false
	}
}

func validAction(action string) bool { return action == "CLAY" || action == "DIRECT" }

type packetLink struct{ *channel.Endpoint }

// The datagrams are plain IP packets. Do not borrow a utun descriptor or prepend
// Apple's private four-byte family header. This endpoint has no interface privileges.
func (link *packetLink) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	return link.Endpoint, stack.NICOptions{}, nil
}
func (link *packetLink) Read(_ []byte) (int, error)  { return 0, errors.ErrUnsupported }
func (link *packetLink) Write(_ []byte) (int, error) { return 0, errors.ErrUnsupported }
func (link *packetLink) Close() error                { link.Endpoint.Close(); return nil }
func (link *packetLink) WritePacket(packet *stack.PacketBuffer) (int, error) {
	var list stack.PacketBufferList
	list.PushBack(packet)
	if count, err := link.WritePackets(list); err != nil || count != 1 {
		return 0, errors.New("packet queue full")
	}
	return packet.Size(), nil
}

type transportHandler struct{ *sing.ListenerHandler }

func (transportHandler) PrepareConnection(string, M.Socksaddr, M.Socksaddr, tun.DirectRouteContext, time.Duration) (tun.DirectRouteDestination, error) {
	return nil, tun.ErrDrop // Do not create a native ICMP socket on mobile.
}

type session struct {
	id     uint64
	ctx    context.Context
	cancel context.CancelFunc
	link   *packetLink
	stack  tun.Stack
	family tcpip.NetworkProtocolNumber
	lab    *labTunnel
}

var engine struct {
	sync.Mutex
	live   *session
	lastID uint64
}

func start(data []byte, chosen, mode int) (uint64, error) {
	engine.Lock()
	defer engine.Unlock()
	if engine.live != nil {
		return 0, errActive
	}
	cfg, err := loadProfile(data, chosen, mode)
	if err != nil {
		return 0, errProfile // The underlying error may contain credentials.
	}
	handler, err := sing.NewListenerHandler(sing.ListenerConfig{Tunnel: tunnel.Tunnel, Type: C.TUN})
	if err != nil {
		return 0, err
	}
	live, err := makeSession(transportHandler{handler}, header.IPv4ProtocolNumber)
	if err != nil {
		return 0, err
	}
	executor.ApplyConfig(cfg, true)
	return publishSession(live), nil
}

func init() {
	// The embedded Lab never applies global configuration. Mute these loggers
	// before there are any packet workers; the Mihomo log level is not atomic.
	glog.SetTarget(&glog.Writer{Next: io.Discard})
	log.SetLevel(log.SILENT)
}

func makeSession(handler tun.Handler, family tcpip.NetworkProtocolNumber) (*session, error) {
	ctx, cancel := context.WithCancel(context.Background())
	link := &packetLink{channel.New(128, mtu, "")}
	options := tun.Options{MTU: mtu}
	if family == header.IPv6ProtocolNumber {
		options.Inet6Address = []netip.Prefix{labNetwork6}
	} else {
		options.Inet4Address = []netip.Prefix{labNetwork4}
	}
	g, err := tun.NewStack("gvisor", tun.StackOptions{
		Context: ctx, Tun: link, TunOptions: options,
		UDPTimeout: 30 * time.Second, ICMPTimeout: time.Second, Handler: handler, Logger: log.SingLogger,
	})
	if err != nil {
		cancel()
		link.Close()
		return nil, err
	}
	if err := g.Start(); err != nil {
		cancel()
		g.Close()
		link.Close()
		return nil, err
	}
	return &session{ctx: ctx, cancel: cancel, link: link, stack: g, family: family}, nil
}

// The engine mutex is held by callers inserting or removing sessions.
func publishSession(live *session) uint64 {
	engine.lastID++
	live.id = engine.lastID
	engine.live = live
	return live.id
}

func stop(id uint64) {
	engine.Lock()
	defer engine.Unlock()
	live := engine.live
	if live == nil || live.id != id {
		return
	}
	engine.live = nil
	if live.lab != nil {
		live.lab.install(nil)
		live.cancel()
		live.stack.Close()
		live.link.Close()
		return
	}
	tunnel.OnSuspend()
	live.cancel()
	live.stack.Close()
	live.link.Close()
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool { _ = c.Close(); return true })
	for _, proxy := range tunnel.Proxies() {
		_ = proxy.Close()
	}
	for _, provider := range tunnel.Providers() {
		if closer, ok := provider.(io.Closer); ok {
			_ = closer.Close()
		}
	}
	tunnel.UpdateProxies(nil, nil)
	tunnel.UpdateRules(nil, nil, nil)
}

func protocol(packet []byte) tcpip.NetworkProtocolNumber {
	if len(packet) < header.IPv4MinimumSize || len(packet) > mtu {
		return 0
	}
	switch packet[0] >> 4 {
	case 4:
		if size := int(packet[0]&15) * 4; size >= header.IPv4MinimumSize && size <= len(packet) &&
			int(binary.BigEndian.Uint16(packet[2:4])) == len(packet) {
			return header.IPv4ProtocolNumber
		}
	case 6:
		if len(packet) >= header.IPv6MinimumSize &&
			int(binary.BigEndian.Uint16(packet[4:6])) == len(packet)-header.IPv6MinimumSize {
			return header.IPv6ProtocolNumber
		}
	}
	return 0
}

func offer(id uint64, packet []byte) bool {
	ip := protocol(packet)
	if ip == 0 {
		return false
	}
	engine.Lock()
	defer engine.Unlock()
	if engine.live == nil || engine.live.id != id || engine.live.family != ip {
		return false
	}
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
	defer pkt.DecRef()
	engine.live.link.InjectInbound(ip, pkt)
	return true
}

func receive(id uint64, out []byte, wait time.Duration) int {
	engine.Lock()
	live := engine.live
	engine.Unlock()
	if live == nil || live.id != id {
		return inactive
	}
	ctx, cancel := context.WithTimeout(live.ctx, wait)
	defer cancel()
	for live.ctx.Err() == nil {
		pkt := live.link.ReadContext(ctx)
		if pkt == nil {
			break
		}
		view := pkt.ToView()
		pkt.DecRef()
		data := view.AsSlice()
		if protocol(data) == live.family && len(data) <= len(out) {
			n := copy(out, data)
			view.Release()
			if live.ctx.Err() != nil {
				return inactive
			}
			return n
		}
		view.Release()
		if ctx.Err() != nil {
			break
		}
	}
	if live.ctx.Err() != nil {
		return inactive
	}
	return 0
}
