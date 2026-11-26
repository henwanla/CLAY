from pathlib import Path
from secrets import token_hex
from socketserver import TCPServer, StreamRequestHandler

NL = bytes((13, 10))
PROOF = ('CLAY_TUN_' + token_hex(12)).encode('ascii')

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

with TCPServer(('127.0.0.1', 0), Proxy) as server:
    Path('fixture-proof').write_bytes(PROOF)
    Path('test-port').write_text(str(server.server_address[1]))
    server.serve_forever()
