from pathlib import Path
from secrets import token_hex
from socketserver import DatagramRequestHandler, TCPServer, ThreadingUDPServer, StreamRequestHandler
from struct import pack
from threading import Thread

NL = bytes((13, 10))
PROOF = ('CLAY_TUN_' + token_hex(12)).encode('ascii')
LABEL = ('probe-' + token_hex(12)).encode('ascii')
QUESTION = bytes([len(LABEL)]) + LABEL + bytes([4]) + b'test' + bytes([0]) + pack('!HH', 1, 1)
QUERY = pack('!HHHHHH', 0x5116, 0x0100, 1, 0, 0, 0) + QUESTION
ANSWER = pack('!HHHIH', 0xc00c, 1, 1, 0, 4) + bytes((203, 0, 113, 73))

class Proxy(StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(2)
        if self.rfile.readline(4096).strip() != b'CONNECT 198.51.100.42:18080 HTTP/1.1':
            return
        for _ in range(20):
            if self.rfile.readline(4096) in (NL, b''):
                break
        else:
            return
        self.wfile.write(b'HTTP/1.1 200 Connection established' + NL * 2)
        if self.rfile.readline(4096).strip() != b'GET /clay-proof HTTP/1.0':
            return
        length = f'Content-Length: {len(PROOF)}'.encode('ascii')
        self.wfile.write(NL.join([b'HTTP/1.0 200 OK', length, b'', PROOF]))

class DNS(DatagramRequestHandler):
    def handle(self):
        # Ignore all traffic except this run's exact, synthetic IPv4 question.
        packet = self.packet
        if len(packet) < 12 or packet[4:6] != pack('!H', 1) or packet[12:12 + len(QUESTION)] != QUESTION:
            return
        self.wfile.write(packet[:2] + pack('!HHHHH', 0x8180, 1, 1, 0, 0) + QUESTION + ANSWER)

with TCPServer(('127.0.0.1', 0), Proxy) as server, ThreadingUDPServer(('127.0.0.1', 0), DNS) as dns:
    Thread(target=dns.serve_forever, daemon=True).start()
    Path('dns-query').write_bytes(QUERY)
    Path('dns-port').write_text(str(dns.server_address[1]))
    Path('fixture-proof').write_bytes(PROOF)
    Path('test-port').write_text(str(server.server_address[1]))
    server.serve_forever()
