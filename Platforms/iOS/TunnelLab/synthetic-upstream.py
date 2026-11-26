#!/usr/bin/env python3
"""One-purpose local VLESS fixture. It never forwards traffic."""
import argparse
import hmac
import ipaddress
import socketserver
import uuid


TARGET = bytes([1, 0x46, 0xA0, 1, 198, 51, 100, 42])  # TCP, 18080, IPv4, TEST-NET-2
PROBE = b"CLAY-VPN-PROBE/1"
REPLY = b"\x00\x00CLAY-LAB-OK/1"


class Request(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(4)
        try:
            with self.request.makefile("rb") as data:
                header = data.read(18)
                if (len(header) != 18 or header[0] != 0 or
                        not hmac.compare_digest(header[1:17], self.server.account.bytes)):
                    return
                if len(data.read(header[17])) != header[17] or data.read(len(TARGET)) != TARGET:
                    return
                if data.read(len(PROBE)) == PROBE:
                    self.request.sendall(REPLY)
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", type=ipaddress.IPv4Address, default=ipaddress.IPv4Address("127.0.0.1"),
                        help="loopback or a specific RFC 1918 address on your machine")
    args = parser.parse_args()
    allowed = ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    if not any(args.bind in ipaddress.IPv4Network(network) for network in allowed):
        parser.error("choose a loopback or private LAN IPv4 address")
    with socketserver.TCPServer((str(args.bind), 0), Request) as listener:
        listener.account = uuid.uuid4()
        print(f"vless://{listener.account}@{args.bind}:{listener.server_address[1]}?type=tcp#CLAY-Lab", flush=True)
        try:
            listener.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
