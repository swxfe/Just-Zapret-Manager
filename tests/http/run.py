from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import ssl
import subprocess
import tempfile
import threading
import time

project = Path.cwd()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path
        body = b'native\x00http\n'
        code, headers = 200, {}
        if path == '/redirect':
            code, headers, body = 302, {'Location': '/ok'}, b''
        elif path == '/loop':
            code, headers, body = 302, {'Location': '/loop'}, b''
        elif path == '/downgrade':
            code, headers, body = 302, {'Location': f'http://127.0.0.1:{plain.server_port}/ok'}, b''
        elif path == '/error':
            code, headers, body = 403, {'X-RateLimit-Remaining': '0'}, b'API failure'
        elif path == '/large':
            body = b'x' * 8192
        elif path == '/slow':
            time.sleep(2)
        self.send_response(code)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(100 if path == '/truncated' else len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError):
            pass

with tempfile.TemporaryDirectory(prefix='jzm-http-') as temporary:
    folder = Path(temporary)
    key, cert = folder / 'key.pem', folder / 'cert.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
                    '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    plain = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    secure = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    secure.socket = context.wrap_socket(secure.socket, server_side=True)
    for server in (plain, secure):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {**os.environ, 'SSL_CERT_FILE': str(cert)}
    env.pop('JZM_HTTP_PROVIDER', None)
    passed = 0

    def request(path, *, tls=False, limit=4096, allow=True, success=True, trusted=True):
        global passed
        server = secure if tls else plain
        url = f'{"https" if tls else "http"}://127.0.0.1:{server.server_port}{path}'
        child_env = dict(env)
        if not trusted:
            child_env['SSL_CERT_FILE'] = '/etc/ssl/certs/ca-certificates.crt'
        completed = subprocess.run(['ucode', '-S', '-L', str(project / 'src/lib'),
                                    'tests/http/client.uc', url, str(limit), '1' if allow else '0'],
                                   env=child_env, capture_output=True, timeout=5)
        assert (completed.returncode == 0) == success, (path, tls, completed.stdout, completed.stderr)
        passed += 1
        return json.loads(completed.stdout) if success else completed.stderr.decode()

    try:
        assert request('/ok')['body'] == 'native\x00http\n'
        assert request('/redirect')['body'] == 'native\x00http\n'
        error = request('/error')
        assert error['status'] == 403 and error['headers']['x-ratelimit-remaining'] == '0'
        request('/large', limit=128, success=False)
        request('/slow', success=False)
        request('/loop', success=False)
        request('/ok', allow=False, success=False)
        assert request('/ok', tls=True, allow=False)['body'] == 'native\x00http\n'
        request('/ok', tls=True, trusted=False, success=False)
        request('/downgrade', tls=True, success=False)
        request('/truncated', success=False)
    finally:
        for server in (plain, secure):
            server.shutdown()
            server.server_close()
    print(f'http: {passed} real native HTTP/TLS, size, timeout, redirect and truncation checks passed')
