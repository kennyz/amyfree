#!/usr/bin/env python3
"""只读取节点 TLS 证书的期限；不发送代理密码、不修改节点的验证选项。"""
import math
import socket
import ssl
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor


def classify_dates(not_before, not_after, now=None, trusted=True):
    now = time.time() if now is None else now
    if not_after <= not_before:
        return {'state': 'unknown', 'reason': '证书日期无法解析'}
    days = math.ceil((not_after - now) / 86400)
    if now < not_before: state = 'not_yet_valid'
    elif now >= not_after: state = 'expired'
    elif not trusted: state = 'untrusted'
    elif not_after - now <= 30 * 86400: state = 'expiring'
    else: state = 'valid'
    return {'state': state, 'not_before': not_before, 'not_after': not_after, 'days_left': days,
            'trusted': trusted, 'checked_at': now}


def tls_target(proxy):
    protocol = proxy.get('type', '').lower()
    if proxy.get('reality-opts'):
        return {'state': 'not_applicable', 'reason': 'REALITY 不使用常规 CA 证书'}
    if protocol in ('hysteria', 'hysteria2', 'tuic', 'quic'):
        return {'state': 'unsupported', 'reason': '暂不支持 QUIC 证书检查'}
    if protocol != 'trojan' and not proxy.get('tls'):
        return {'state': 'not_applicable', 'reason': '此节点未使用 TLS'}
    host = proxy.get('server')
    port = proxy.get('port')
    if not host or not isinstance(port, int):
        return {'state': 'unknown', 'reason': '缺少 TLS 服务器地址'}
    return (host, port, proxy.get('servername') or proxy.get('sni') or host)


def read_dates(der):
    # 使用系统解析器读取 ASN.1 日期；DER 仅在管道中传递，不写入项目或日志。
    result = subprocess.run(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-noout', '-dates'],
                            input=der, capture_output=True, timeout=2)
    if result.returncode: raise ValueError('invalid certificate')
    fields = dict(line.split('=', 1) for line in result.stdout.decode().splitlines() if '=' in line)
    return ssl.cert_time_to_seconds(fields['notBefore']), ssl.cert_time_to_seconds(fields['notAfter'])


def inspect_certificate(proxy, timeout=3):
    target = tls_target(proxy)
    if isinstance(target, dict): return target
    host, port, hostname = target
    def handshake(context):
        alpn = proxy.get('alpn')
        if isinstance(alpn, list) and all(isinstance(value, str) for value in alpn):
            context.set_alpn_protocols(alpn)
        with socket.create_connection((host, port), timeout=timeout) as transport:
            with context.wrap_socket(transport, server_hostname=hostname) as connection:
                return connection.getpeercert(binary_form=True)
    trusted = True
    try:
        try:
            der = handshake(ssl.create_default_context())
        except ssl.SSLCertVerificationError:
            trusted = False
            # 仅在诊断连接中取回证书日期；无 HTTP/代理认证数据，结果保留“不受信”状态。
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            der = handshake(context)
        before, after = read_dates(der)
        result = classify_dates(before, after, trusted=trusted)
        if not trusted: result['reason'] = '证书信任或域名校验未通过'
        return result
    except Exception:
        return {'state': 'unknown', 'reason': '无法读取服务器证书', 'checked_at': time.time()}


def combine_certificates(certificates):
    rank = {'expired': 0, 'not_yet_valid': 1, 'untrusted': 2, 'unknown': 3, 'unsupported': 3,
            'expiring': 4, 'valid': 5, 'not_applicable': 6}
    if not certificates: return {'state': 'unknown', 'reason': '无法确认链路证书'}
    selected = min(certificates, key=lambda item: (rank.get(item['state'], 3), item.get('not_after', float('inf'))))
    result = dict(selected)
    result['chain'] = True
    result['reason'] = '入口与出口中最需关注的证书' + ('；' + result['reason'] if result.get('reason') else '')
    return result


def certificate_batch(directory):
    from pathlib import Path
    from parse_sub import parse_subscription
    from chain_proxy import read_state, EXIT
    proxies, _, _ = parse_subscription(Path(directory) / 'providers/nodes.yaml')
    with ThreadPoolExecutor(max_workers=3) as pool:
        values = list(pool.map(inspect_certificate, proxies))
    result = {proxy['name']: value for proxy, value in zip(proxies, values)}
    chain = read_state(directory)
    if chain.get('enabled'):
        result[EXIT] = combine_certificates([result.get(chain.get(key), {'state': 'unknown'}) for key in ('entry', 'exit')])
    return result
