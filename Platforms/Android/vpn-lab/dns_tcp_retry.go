package tunnel

import (
	"net/netip"
	"os"

	C "github.com/metacubex/mihomo/constant"
	"github.com/miekg/dns"
)

// Set only in the private VPN engine process, from the same validated address
// that Android's VpnService.Builder installs. The Relay engine has no hook.
var clayVPNResolver, _ = netip.ParseAddr(os.Getenv("CLAY_VPN_RESOLVER"))

func clayRetryDNSOverTCP(packet C.PacketAdapter, metadata *C.Metadata) bool {
	if metadata.Type != C.TUN || !clayVPNResolver.IsValid() ||
		metadata.AddrPort() != netip.AddrPortFrom(clayVPNResolver, 53) {
		return false
	}
	payload := packet.Data()
	if len(payload) < 12 || len(payload) > 4096 {
		return false
	}
	var question dns.Msg
	if question.Unpack(payload) != nil || question.Response || question.Opcode != dns.OpcodeQuery ||
		len(question.Question) != 1 || len(question.Answer) != 0 || len(question.Ns) != 0 ||
		len(question.Extra) > 1 || (len(question.Extra) == 1 && question.IsEdns0() == nil) {
		return false
	}

	// Check the route a TCP retry to this exact address would use. CLAY's
	// rules match names/IPs, have no transport predicates, and do not sniff
	// this port. UDP-capable and intentional Direct routes keep normal DNS.
	route := metadata.Clone()
	route.NetWork = C.TCP
	proxy, _, err := resolveMetadata(route)
	if err != nil || proxy == nil || proxy.SupportUDP() {
		return false
	}

	// TC tells the OS resolver to reconnect to the same address using TCP.
	// No query is sent here, and no alternate resolver or route is installed.
	response := new(dns.Msg).SetReply(&question)
	response.Truncated = true
	data, err := response.Pack()
	if err != nil {
		return false
	}
	_, _ = packet.WriteBack(data, metadata.UDPAddr())
	return true
}
