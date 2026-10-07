"""用真实 mihomo 和带慢握手的本地代理验证：连接时间不能冒充响应 RTT。"""
import json
from pathlib import Path
import shutil
import socketserver
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.parse
import urllib.request
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mihomo'))
import node_speed


class SlowHandshake(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)
        line = self.rfile.readline()
        if not line.startswith(b'CONNECT '): return
        while self.rfile.readline() not in (b'\r\n', b'\n', b''): pass
        time.sleep(.65)
        self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n'); self.wfile.flush()
        while self.rfile.readline():
            while self.rfile.readline() not in (b'\r\n', b'\n', b''): pass
            time.sleep(.015)
            self.wfile.write(b'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'); self.wfile.flush()


class ProxyServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class LatencyMetricTests(unittest.TestCase):
    @unittest.skipUnless((Path.home()/'.config/mihomo/mihomo').exists(), '需要已安装的 mihomo 内核')
    def test_unified_metric_excludes_slow_connection_setup(self):
        with ProxyServer(('127.0.0.1',0), SlowHandshake) as proxy, tempfile.TemporaryDirectory() as directory:
            thread = threading.Thread(target=proxy.serve_forever, daemon=True); thread.start()
            root = Path(directory); (root/'providers').mkdir()
            (root/'mihomo').symlink_to(Path.home()/'.config/mihomo/mihomo')
            (root/'providers/nodes.yaml').write_text(json.dumps({'proxies':[{'name':'fixture','type':'http','server':'127.0.0.1','port':proxy.server_address[1]}]}))
            original = node_speed.latency_config
            measured = []
            try:
                for enabled in (False, True):
                    def builder(*args):
                        config = original(*args); config['unified-delay'] = enabled; return config
                    with patch.object(node_speed, 'latency_config', side_effect=builder), node_speed.latency_session(root) as (api, secret):
                        query = urllib.parse.urlencode({'url':'http://probe.invalid/check','timeout':3000})
                        request = urllib.request.Request(f'http://{api}/proxies/fixture/delay?{query}',headers={'Authorization':'Bearer '+secret})
                        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
                        with opener.open(request,timeout=5) as response: measured.append(json.load(response)['delay'])
                self.assertGreaterEqual(measured[0], 600)
                self.assertGreater(measured[1], 0)
                self.assertLess(measured[1], 200)
                print('慢握手回归：首次耗时', measured[0], 'ms；统一响应延迟', measured[1], 'ms')
            finally:
                proxy.shutdown(); thread.join(timeout=2)


if __name__=='__main__': unittest.main()
