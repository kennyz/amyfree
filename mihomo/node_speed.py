#!/usr/bin/env python3
"""在隔离的代理会话中测指定订阅节点的短时下载速度，不切换主代理。"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.parse
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from parse_sub import parse_subscription, to_yaml
from chain_proxy import read_state, chain_nodes, EXIT
from cert_probe import certificate_batch

SAMPLE_BYTES = 1_000_000
DOWNLOAD_URL = 'https://speed.cloudflare.com/__down?bytes=1000000'


def probe_dns():
    # 不借用系统的 fake-IP 解析；否则链式出口可能被入口拨到不可路由的 fake-IP。
    doh = 'https://dns.alidns.com/dns-query'
    return {'enable': True, 'listen': '127.0.0.1:0', 'ipv6': False, 'enhanced-mode': 'redir-host',
            'respect-rules': False, 'default-nameserver': ['223.5.5.5', '119.29.29.29'],
            'nameserver': [doh], 'proxy-server-nameserver': [doh], 'direct-nameserver': [doh]}


def fingerprint(directory):
    try:
        stat = (Path(directory) / 'providers/nodes.yaml').stat()
        result = f'{stat.st_ino}:{stat.st_mtime_ns}:{stat.st_size}'
        chain = Path(directory) / '.mimio-chain.json'
        if chain.exists():
            other = chain.stat()
            result += f':{other.st_mtime_ns}:{other.st_size}'
        return result
    except OSError:
        return 'missing'


def catalogue(directory):
    proxies, _, _ = parse_subscription(Path(directory) / 'providers/nodes.yaml')
    state = read_state(directory)
    names = [proxy['name'] for proxy in proxies]
    labels = {}
    if state.get('enabled'):
        names.append(EXIT)
        labels[EXIT] = '链式代理 · ' + state['entry'] + ' → ' + state['exit']
    return {'fingerprint': fingerprint(directory), 'names': names, 'labels': labels, 'chain': state}


def latency_config(proxies, port, secret):
    # URLTest 使用同一连接上的第二次响应计时，避免把首次 DNS/TCP/TLS 开销当作 RTT。
    return {'mixed-port': 0, 'external-controller': f'127.0.0.1:{port}', 'secret': secret,
            'allow-lan': False, 'mode': 'rule', 'log-level': 'error', 'ipv6': False,
            'unified-delay': True, 'dns': probe_dns(), 'proxies': proxies, 'rules': ['MATCH,DIRECT']}


@contextlib.contextmanager
def latency_session(directory):
    directory = Path(directory)
    proxies, _, _ = parse_subscription(directory / 'providers/nodes.yaml')
    state = read_state(directory)
    if state.get('enabled'): proxies += chain_nodes(proxies, state['entry'], state['exit'])
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
    secret = os.urandom(20).hex()
    process = None
    with tempfile.TemporaryDirectory(prefix='mimio-latency-') as temporary:
        work = Path(temporary)
        config = latency_config(proxies, port, secret)
        path = work / 'config.yaml'; path.write_text(to_yaml(config) + '\n'); os.chmod(path, 0o600)
        try:
            with (work / 'private.log').open('wb') as log:
                process = subprocess.Popen([str(directory / 'mihomo'), '-d', str(work), '-f', str(path)],
                                           stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            for _ in range(40):
                if process.poll() is not None: raise ValueError('检测会话无法启动')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                except OSError: time.sleep(.05)
            else: raise ValueError('检测会话启动超时')
            yield f'127.0.0.1:{port}', secret
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)


def latency_batch(directory):
    result = catalogue(directory)
    # 检测始终独立于主代理，避免 url-test 组因新的延迟记录改变当前选路。
    with ThreadPoolExecutor(max_workers=1) as checks:
        certificates = checks.submit(certificate_batch, directory)
        with latency_session(directory) as (api, secret):
            result = check_latencies(result, api, secret, isolated=True)
        result['certificates'] = certificates.result()
        return result


def check_latencies(result, api, secret, isolated):
    result['paused'] = False
    def check(name):
        encoded = urllib.parse.quote(name, safe='')
        path = f'/proxies/{encoded}/delay' if isolated or name == EXIT else f'/providers/proxies/nodes/{encoded}/healthcheck'
        query = urllib.parse.urlencode({'timeout': 6000, 'url': 'https://www.gstatic.com/generate_204'})
        req = urllib.request.Request(f'http://{api}{path}?{query}', headers={'Authorization': 'Bearer ' + secret})
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=8) as response: value = json.load(response)
            delay = value.get('delay', 0)
            return {'name': name, 'delay': delay, 'error': '' if delay > 0 else '检测未通过'}
        except urllib.error.HTTPError as error:
            return {'name': name, 'delay': 0, 'error': '节点更新中' if error.code in (401, 404) else '超时或连接失败',
                    'service_error': error.code in (401, 404)}
        except Exception:
            return {'name': name, 'delay': 0, 'error': '内核连接中断', 'service_error': True}
    with ThreadPoolExecutor(max_workers=3) as pool:
        result['results'] = list(pool.map(check, result['names']))
    return result


def speed_from_sample(status, received, seconds):
    if status != 200 or received != SAMPLE_BYTES or seconds <= 0:
        raise ValueError('下载样本未完成')
    return received / seconds / 1_000_000


def measure(directory, name):
    directory = Path(directory)
    proxies, _, _ = parse_subscription(directory / 'providers/nodes.yaml')
    if name == EXIT:
        state = read_state(directory)
        if not state.get('enabled'): raise ValueError('链式代理未开启')
        proxies += chain_nodes(proxies, state['entry'], state['exit'])
    node = next((proxy for proxy in proxies if proxy['name'] == name), None)
    if node is None:
        raise ValueError('订阅节点已变化，请重新检测')
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    process = None
    with tempfile.TemporaryDirectory(prefix='mimio-download-') as temporary:
        work = Path(temporary)
        # 独立配置只含指定节点，MATCH 强制走该节点；无 TUN、控制接口或系统代理改动。
        config = {'mixed-port': port, 'bind-address': '127.0.0.1', 'allow-lan': False,
                  'mode': 'rule', 'log-level': 'error', 'ipv6': False,
                  'dns': probe_dns(), 'proxies': proxies,
                  'proxy-groups': [{'name': 'MIMIO_SPEED_TEST', 'type': 'select', 'proxies': [name]}],
                  'rules': ['MATCH,MIMIO_SPEED_TEST']}
        path = work / 'config.yaml'
        path.write_text(to_yaml(config) + '\n', encoding='utf-8')
        os.chmod(path, 0o600)
        try:
            with (work / 'private.log').open('wb') as log:
                process = subprocess.Popen([str(directory / 'mihomo'), '-d', str(work), '-f', str(path)],
                                           stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
            ready = False
            for _ in range(40):
                if process.poll() is not None:
                    break
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        ready = True
                        break
                except OSError:
                    time.sleep(.05)
            if not ready:
                raise ValueError('无法启动隔离测速会话')
            result = subprocess.run(['curl', '-sS', '--proxy', f'http://127.0.0.1:{port}',
                                     '--noproxy', '', '--connect-timeout', '6', '--max-time', '12',
                                     '-H', 'Accept-Encoding: identity', '-o', os.devnull,
                                     '-w', '%{http_code} %{size_download} %{time_total}', DOWNLOAD_URL],
                                    capture_output=True, text=True, timeout=14)
            if result.returncode:
                raise ValueError('下载测速超时或连接失败')
            status, received, seconds = result.stdout.split()
            speed = speed_from_sample(int(status), int(float(received)), float(seconds))
            return {'ok': True, 'megabytes_per_second': speed, 'bytes': SAMPLE_BYTES,
                    'seconds': float(seconds)}
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', default=str(Path(__file__).resolve().parent))
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--latency', action='store_true')
    parser.add_argument('--node')
    args = parser.parse_args()
    os.umask(0o077)
    # 原生 App 取消/退出时也能进入 finally，清理隔离内核。
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        if args.latency:
            result = latency_batch(args.home)
        elif args.list:
            result = catalogue(args.home)
        elif args.node:
            result = measure(args.home, args.node)
        else:
            raise ValueError('请选择一个节点')
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception as error:
        message = str(error) if isinstance(error, ValueError) else '无法读取节点或执行测速'
        print(json.dumps({'ok': False, 'error': message}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    sys.exit(main())
