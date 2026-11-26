#!/usr/bin/env python3
"""Real two-core test. All servers and data stays on 127.0.0.1."""
import argparse
import base64
from contextlib import ExitStack
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlencode
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('clayctl', type=Path)
parser.add_argument('mihomo', type=Path)
parser.add_argument('xray', type=Path)
a = parser.parse_args()
engine, tool, xray = (p.resolve(strict=True) for p in (a.mihomo, a.clayctl, a.xray))

def read_system_proxy():
    return subprocess.check_output(['/usr/sbin/scutil', '--proxy'])

before = read_system_proxy()
with tempfile.TemporaryDirectory(prefix='clay-fixtures-') as tmp, ExitStack() as stack:
    tmp = Path(tmp)
    env = {'HOME': str(tmp), 'TMPDIR': str(tmp), 'PATH': '/usr/bin:/bin'}
    token = secrets.token_hex(20)
    account = str(uuid.uuid4())

    class Origin(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/telemetry':
                # Leave enough time to observe the active connection and let
                # the controller close it before this response is complete.
                self.send_response(200); self.send_header('Content-Length', '65536'); self.end_headers()
                self.wfile.write(b'x' * 4096); self.wfile.flush()
                self.connection.settimeout(9)
                try: self.connection.recv(1)
                except OSError: pass
                return
            if self.path != '/probe': self.send_error(404); return
            self.send_response(200); self.send_header('Content-Length', str(len(token))); self.end_headers()
            self.wfile.write(token.encode())
        def log_message(self, *args): pass

    origin = stack.enter_context(http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin))
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    stack.callback(origin.shutdown)
    ports = []
    with ExitStack() as pending:
        for _ in range(6):
            s = pending.enter_context(socket.socket()); s.bind(('127.0.0.1', 0)); ports.append(s.getsockname()[1])
    cert, key = tmp / 'crt.pem', tmp / 'key.pem'
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-nodes', '-days', '1', '-newkey', 'rsa:2048', '-keyout', key, '-out', cert, '-subj', '/CN=clay.test'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    vmess_tcp, vless_tcp, vless_ws, vless_grpc, vless_reality, decoy_port = ports
    keys = dict(line.split(':', 1) for line in subprocess.check_output([xray, 'x25519'], env=env, text=True).splitlines() if ':' in line)
    private_key = keys['PrivateKey'].strip()
    public_key = (keys.get('Password (PublicKey)') or keys.get('Password') or keys['PublicKey']).strip()
    short_id = secrets.token_hex(8)
    config = {'log': {'loglevel': 'debug' if os.getenv('CLAY_TRACE_SYNTHETIC') == '1' else 'warning'}, 'inbounds': [], 'outbounds': [{'protocol': 'freedom', 'tag': 'local', 'settings': {'finalRules': [
        {'action': 'allow', 'network': 'tcp', 'port': str(origin.server_port), 'ip': ['127.0.0.1/32']},
        {'action': 'block'},
    ]}}]}
    for protocol, port, stream in [
        ('vmess', vmess_tcp, {'network':'tcp'}), ('vless', vless_tcp, {'network':'tcp'}),
        ('vless', vless_ws, {'network':'ws', 'wsSettings': {'path':'/clay'}, 'security':'tls', 'tlsSettings': {'certificates':[{'certificateFile': str(cert), 'keyFile': str(key)}]}}),
        ('vless', vless_grpc, {'network':'grpc', 'grpcSettings':{'serviceName':'clay'}}),
        ('vless', vless_reality, {'network':'raw', 'security':'reality', 'realitySettings': {
            'target': f'127.0.0.1:{decoy_port}', 'serverNames': ['clay.test'], 'minClientVer': '1.8.2', 'privateKey': private_key, 'shortIds': [short_id],
        }}),
    ]:
        settings = {'clients': [{'id': account}]}
        if protocol == 'vless': settings['decryption'] = 'none'
        if port == vless_reality: settings['clients'][0]['flow'] = 'xtls-rprx-vision'
        config['inbounds'].append({'listen': '127.0.0.1','port': port,'protocol': protocol,'settings': settings,'streamSettings': stream})
    config['inbounds'].append({'listen':'127.0.0.1','port':decoy_port,'protocol':'dokodemo-door',
        'settings':{'address':'127.0.0.1','port':origin.server_port,'network':'tcp'},
        'streamSettings':{'network':'raw','security':'tls','tlsSettings': {'minVersion':'1.3','alpn':['h2','http/1.1'],
            'certificates':[{'certificateFile':str(cert),'keyFile':str(key)}]}}})
    server_config = tmp / 'server.json'; server_config.write_text(json.dumps(config)); server_config.chmod(0o600)
    with (tmp / 'server.log').open('w+') as log, subprocess.Popen([xray, 'run', '-config', server_config], cwd=tmp, env=env, stdout=log, stderr=subprocess.STDOUT) as server:
        try:
            for port in ports:
                for attempt in range(100):
                    if server.poll() is not None:
                        log.seek(0); raise RuntimeError('Synthetic Xray failed: ' + log.read(3000))
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                    except OSError: time.sleep(.05)
                else: raise RuntimeError('Synthetic Xray failed to bind')
            vmess = base64.b64encode(json.dumps({'add':'127.0.0.1','id':account,'port':vmess_tcp,'net':'tcp','aid':'0'}).encode()).decode()
            def vless(port, **query): return f'vless://{account}@127.0.0.1:{port}?'+urlencode(query)
            profiles = tmp / 'profiles.txt'; profiles.write_text('\n'.join([
                'vmess://'+vmess, vless(vless_tcp, type='tcp'),
                vless(vless_ws, type='ws', security='tls', path='/clay', allowInsecure='1'),
                vless(vless_grpc, type='grpc', serviceName='clay'),
                vless(vless_reality, type='tcp', security='reality', fp='chrome', sni='clay.test', pbk=public_key, sid=short_id, flow='xtls-rprx-vision', **{'support-x25519mlkem768':'true'}),
            ])); profiles.chmod(0o600)
            target = f'http://127.0.0.1:{origin.server_port}/probe'
            result = subprocess.run([tool,'smoke',profiles,engine,target,token], env=env, timeout=50)
            if result.returncode:
                if os.getenv('CLAY_TRACE_SYNTHETIC') == '1':
                    log.seek(0); print(log.read()[-5000:])
                raise RuntimeError(f'Synthetic smoke failed ({result.returncode})')
            telemetry_target = f'http://127.0.0.1:{origin.server_port}/telemetry'
            subprocess.run([tool, 'smoke-telemetry', profiles, engine, telemetry_target], env=env, timeout=15, check=True)
            profiles.write_text(vless(vless_tcp, type='tcp').replace(account, str(uuid.uuid4())))
            failed = subprocess.run([tool,'smoke',profiles,engine,target,token], text=True, capture_output=True, env=env, timeout=20)
            assert failed.returncode == 1 and 'FAIL probeFailed' in failed.stdout, failed.stdout
            print('PASS invalid VLESS credentials did not fall back to a direct connection')
        finally:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired: server.kill(); server.wait()

    # A generated cert and its native Mihomo fingerprint keep the QUIC
    # fixture off the system trust store.
    fingerprint = hashlib.sha256(subprocess.check_output(
        ['/usr/bin/openssl', 'x509', '-outform', 'DER', '-in', cert], env=env)).hexdigest()
    local_config = {'log-level': 'info', 'mode': 'rule', 'ipv6': False, 'listeners': [], 'rules': [
        f'AND,((IP-CIDR,127.0.0.1/32),(DST-PORT,{origin.server_port})),DIRECT', 'MATCH,REJECT',
    ]}
    nodes = []
    rejected = []
    with ExitStack() as pending:
        for obfs in (None, 'salamander', 'gecko'):
            udp = pending.enter_context(socket.socket(type=socket.SOCK_DGRAM)); udp.bind(('127.0.0.1', 0))
            port = udp.getsockname()[1]
            password = secrets.token_hex(24)
            node = {'name': obfs or 'plain', 'type': 'hysteria2', 'server': '127.0.0.1', 'port': port,
                    'password': password, 'sni': 'clay.test', 'fingerprint': fingerprint}
            listener = {'name': node['name'], 'type': 'hysteria2', 'listen': '127.0.0.1', 'port': str(port),
                        'users': {'fixture': password}, 'certificate': str(cert), 'private-key': str(key)}
            if obfs:
                fields = {'obfs': obfs, 'obfs-password': secrets.token_hex(24)}
                node.update(fields); listener.update(fields)
            nodes.append(node); local_config['listeners'].append(listener)
        for relay in ('native', 'quic'):
            udp = pending.enter_context(socket.socket(type=socket.SOCK_DGRAM)); udp.bind(('127.0.0.1', 0))
            port = udp.getsockname()[1]
            password = secrets.token_hex(24)
            name = 'tuic-' + relay
            nodes.append({'name': name, 'type': 'tuic', 'server': '127.0.0.1', 'port': port, 'uuid': account,
                          'password': password, 'sni': 'clay.test', 'fingerprint': fingerprint, 'udp-relay-mode': relay})
            local_config['listeners'].append({'name': name, 'type': 'tuic', 'listen': '127.0.0.1', 'port': str(port),
                                            'users': {account: password}, 'certificate': str(cert), 'private-key': str(key)})

        rejected.extend({**node, 'fingerprint': secrets.token_hex(32)} for node in (nodes[0], nodes[-1]))
        for method, key_bytes, identity in (('aes-128-gcm', 16, True), ('aes-256-gcm', 32, True),
                                             ('chacha20-poly1305', 32, False)):
            tcp = pending.enter_context(socket.socket()); tcp.bind(('127.0.0.1', 0))
            port = tcp.getsockname()[1]
            name, cipher = 'ss2022-' + method, '2022-blake3-' + method
            server_key = base64.b64encode(secrets.token_bytes(key_bytes)).decode('ascii')
            user_key = base64.b64encode(secrets.token_bytes(key_bytes)).decode('ascii')
            password = server_key + ':' + user_key if identity else server_key
            node = {'name': name, 'type': 'ss', 'server': '127.0.0.1', 'port': port, 'cipher': cipher, 'password': password}
            listener = {'name': name, 'type': 'shadowsocks', 'listen': '127.0.0.1', 'port': str(port),
                        'cipher': cipher, 'password': server_key}
            if identity:
                listener['users'] = {'fixture': user_key}
            local_config['listeners'].append(listener)
            nodes.append(node)
            wrong_key = base64.b64encode(secrets.token_bytes(key_bytes)).decode('ascii')
            rejected.append({**node, 'password': server_key + ':' + wrong_key if identity else wrong_key})

    local_profiles = tmp / 'local-profiles.json'; local_profiles.write_text(json.dumps({'proxies': nodes})); local_profiles.chmod(0o600)
    local_server = tmp / 'local-server.json'; local_server.write_text(json.dumps(local_config)); local_server.chmod(0o600)
    subprocess.run([tool, 'verify-config', local_profiles, engine], env=env, timeout=15, check=True)
    local_log = tmp / 'local-server.log'
    with local_log.open('w') as log, subprocess.Popen([engine, '-d', tmp, '-f', local_server], cwd=tmp, env=env, stdout=log, stderr=subprocess.STDOUT) as server:
        try:
            for _ in range(100):
                if server.poll() is not None: raise RuntimeError('Synthetic Mihomo server failed')
                output = local_log.read_text()
                if all(f'[{node["name"]}] proxy listening' in output for node in nodes): break
                time.sleep(.05)
            else: raise RuntimeError('Synthetic Mihomo server did not bind all listeners')
            subprocess.run([tool, 'smoke', local_profiles, engine, target, token], env=env, timeout=40, check=True)
            for candidate in rejected:
                local_profiles.write_text(json.dumps({'proxies': [candidate]}))
                failed = subprocess.run([tool, 'smoke', local_profiles, engine, target, token], text=True, capture_output=True, env=env, timeout=20)
                assert failed.returncode == 1 and 'FAIL probeFailed' in failed.stdout, 'Invalid upstream credentials were not rejected'
            print('PASS Shadowsocks 2022, Hysteria2 and TUIC forwarding; invalid keys and certificates refused')
        finally:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
assert read_system_proxy() == before
print('PASS system proxy state unchanged')
