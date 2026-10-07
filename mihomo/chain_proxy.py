#!/usr/bin/env python3
"""Amyfree 两跳链式代理：只更新托管节点与代理组，保留其余配置。"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request
from parse_sub import load_yaml, parse_subscription, to_yaml, SubscriptionError
from subscription import atomic_write

ENTRY = 'MIMIO_CHAIN_ENTRY'
EXIT = 'MIMIO_CHAIN_EXIT'
GROUPS = ('PROXY', '手动选择')
CHAIN_DNS = ['https://dns.alidns.com/dns-query']


def read_state(directory):
    path = Path(directory) / '.mimio-chain.json'
    if not path.exists():
        return {'enabled': False, 'entry': '', 'exit': ''}
    value = json.loads(path.read_text())
    return value


def chain_nodes(proxies, entry, exit):
    if entry == exit:
        raise SubscriptionError('入口和出口请选择不同的节点。')
    mapping = {proxy['name']: proxy for proxy in proxies}
    if entry not in mapping or exit not in mapping:
        raise SubscriptionError('入口或出口已不在订阅中，请重新选择。')
    if any(mapping[name]['type'] in ('direct', 'reject') for name in (entry, exit)):
        raise SubscriptionError('请选择两个实际代理节点作为入口和出口。')
    if any(proxy['name'] in (ENTRY, EXIT) for proxy in proxies):
        raise SubscriptionError('节点名称与链式代理保留名称冲突。')
    first = copy.deepcopy(mapping[entry]); first['name'] = ENTRY
    first.pop('dialer-proxy', None)
    last = copy.deepcopy(mapping[exit]); last['name'] = EXIT
    last['dialer-proxy'] = ENTRY
    return [first, last]


def replace_block(source, key, value):
    lines = source.splitlines(keepends=True)
    starts = [index for index, line in enumerate(lines) if re.match(r'^' + re.escape(key) + r'\s*:', line)]
    if len(starts) > 1:
        raise SubscriptionError('配置存在重复字段，暂不能修改链式代理。')
    replacement = '' if value is None else to_yaml({key: value}) + '\n'
    if not starts:
        return source + ('\n' if source and not source.endswith('\n') else '') + replacement
    start = starts[0]; end = start + 1
    while end < len(lines) and not re.match(r'^[A-Za-z0-9_-]+\s*:', lines[end]):
        end += 1
    # 保留下一节之前的空行和顶层注释。
    while end > start + 1 and (not lines[end - 1].strip() or lines[end - 1].startswith('#')):
        end -= 1
    return ''.join(lines[:start]) + replacement + ''.join(lines[end:])


def render(source, proxies, previous, enabled, entry, exit):
    data = load_yaml(source)
    existing = data.get('proxies') or []
    groups = data.get('proxy-groups') or []
    if not isinstance(existing, list) or not isinstance(groups, list):
        raise SubscriptionError('当前代理组配置格式暂不支持链式设置。')
    if not previous.get('enabled') and any(proxy.get('name') in (ENTRY, EXIT) for proxy in existing):
        raise SubscriptionError('当前配置已有同名保留节点，请先更名。')
    if previous.get('enabled'):
        for group in groups:
            if group.get('name') in GROUPS and group != {'name': group['name'], 'type': 'select', 'proxies': [EXIT]}:
                raise SubscriptionError('链式代理组已被手工修改，请先恢复代理组设置。')
    kept = [proxy for proxy in existing if proxy.get('name') not in (ENTRY, EXIT)]
    original = previous.get('original_groups') if previous.get('enabled') else [copy.deepcopy(group) for group in groups if group.get('name') in GROUPS]
    if enabled:
        if not original or not any(group.get('name') == 'PROXY' for group in original):
            raise SubscriptionError('当前配置缺少 PROXY 代理组。')
        kept += chain_nodes(proxies, entry, exit)
        groups = [{'name': group['name'], 'type': 'select', 'proxies': [EXIT]} if group.get('name') in GROUPS else group for group in groups]
    elif previous.get('enabled'):
        originals = {group['name']: group for group in original}
        groups = [originals.get(group.get('name'), group) for group in groups]
    updated = replace_block(source, 'proxies', kept if kept else None)
    updated = replace_block(updated, 'proxy-groups', groups)
    state = {'enabled': enabled, 'entry': entry, 'exit': exit}
    dns = copy.deepcopy(data.get('dns') or {})
    if enabled:
        state['original_groups'] = original
        for key in ('enable', 'proxy-server-nameserver'):
            saved_key = 'original_dns_' + key
            state[saved_key] = previous.get(saved_key) if previous.get('enabled') else {'exists': key in dns, 'value': dns.get(key)}
        # 只改变代理服务器地址的解析，避免把 fake-IP 发给远端入口；网站/局域网 DNS 保留。
        dns['enable'] = True
        dns['proxy-server-nameserver'] = CHAIN_DNS
        updated = replace_block(updated, 'dns', dns)
    elif previous.get('enabled'):
        for key, managed in [('enable', True), ('proxy-server-nameserver', CHAIN_DNS)]:
            saved = previous.get('original_dns_' + key)
            if saved and dns.get(key) == managed:
                if saved['exists']: dns[key] = saved['value']
                else: dns.pop(key, None)
        updated = replace_block(updated, 'dns', dns if dns else None)
    return updated, state


def running(directory):
    try:
        os.kill(int((Path(directory) / '.mihomo.pid').read_text().strip()), 0)
        return True
    except (OSError, ValueError):
        return False


def subscription_updates(directory, proxies):
    """刷新订阅时同步链式节点的凭据；已删除的入口/出口自动取消链式。"""
    directory = Path(directory)
    previous = read_state(directory)
    if not previous.get('enabled'): return {}
    names = {proxy['name'] for proxy in proxies}
    enabled = previous['entry'] in names and previous['exit'] in names
    source = (directory / 'config.yaml').read_text()
    updated, state = render(source, proxies, previous, enabled, previous['entry'], previous['exit'])
    secret = (directory / '.api-secret').read_text().strip()
    result = {directory/'config.yaml': updated.encode(),
              directory/'.run-config.yaml': updated.replace('__API_SECRET__', secret).encode(),
              directory/'.mimio-chain.json': json.dumps(state, ensure_ascii=False).encode()}
    notun = directory/'.config.yaml.notun'
    if notun.exists(): result[notun] = render(notun.read_text(), proxies, previous, enabled, previous['entry'], previous['exit'])[0].encode()
    return result


def reload_runtime(directory, path, expected):
    secret = (Path(directory) / '.api-secret').read_text().strip()
    api = os.environ.get('MIHOMO_API', '127.0.0.1:9090')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(f'http://{api}/configs?force=true', data=json.dumps({'path': str(path)}).encode(), method='PUT',
                                 headers={'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/json'})
    with opener.open(req, timeout=12):
        pass
    req = urllib.request.Request(f'http://{api}/proxies/PROXY', headers={'Authorization': 'Bearer ' + secret})
    with opener.open(req, timeout=5) as response:
        group = json.load(response)
    if expected.get('enabled') and group.get('now') != EXIT:
        raise SubscriptionError('内核未采用链式出口。')
    if not expected.get('enabled') and group.get('now') == EXIT:
        raise SubscriptionError('内核尚未退出链式代理。')


def apply(directory, enabled, entry, exit):
    directory = Path(directory)
    source_path = directory / 'config.yaml'
    source = source_path.read_text()
    proxies, _, _ = parse_subscription(directory / 'providers/nodes.yaml')
    previous = read_state(directory)
    if not enabled and not previous.get('enabled'):
        state = {'enabled': False, 'entry': entry, 'exit': exit}
        atomic_write(directory / '.mimio-chain.json', json.dumps(state, ensure_ascii=False).encode())
        return state
    updated, state = render(source, proxies, previous, enabled, entry, exit)
    secret = (directory / '.api-secret').read_text().strip()
    runtime = updated.replace('__API_SECRET__', secret)
    runtime_path = directory / '.run-config.yaml'
    metadata = directory / '.mimio-chain.json'
    updates = {source_path: updated.encode(), runtime_path: runtime.encode(), metadata: json.dumps(state, ensure_ascii=False).encode()}
    notun = directory / '.config.yaml.notun'
    if notun.exists():
        updates[notun] = render(notun.read_text(), proxies, previous, enabled, entry, exit)[0].encode()
    with tempfile.TemporaryDirectory(prefix='.chain-validate-', dir=directory) as temporary:
        candidate = Path(temporary) / 'config.yaml'
        candidate.write_text(runtime); os.chmod(candidate, 0o600)
        result = subprocess.run([str(directory / 'mihomo'), '-t', '-d', str(directory), '-f', str(candidate)], capture_output=True, timeout=20)
        if result.returncode:
            raise SubscriptionError('链式配置未通过内核检查，本次未保存。')
    if source_path.read_text() != source:
        raise SubscriptionError('配置已发生变化，请重新打开设置。')
    snapshots = {path: path.read_bytes() if path.exists() else None for path in updates}
    active = running(directory)
    attempted = False
    try:
        for path, content in updates.items(): atomic_write(path, content)
        if active:
            attempted = True
            reload_runtime(directory, runtime_path, state)
    except Exception:
        for path, content in snapshots.items():
            if content is None: path.unlink(missing_ok=True)
            else: atomic_write(path, content)
        if attempted:
            if not runtime_path.exists(): atomic_write(runtime_path, source.replace('__API_SECRET__', secret).encode())
            try: reload_runtime(directory, runtime_path, previous)
            except Exception: raise SubscriptionError('保存失败，文件已恢复，但内核还原失败，请重新启动代理。') from None
        raise SubscriptionError('链式设置未生效，已恢复原配置。') from None
    state['applied'] = active
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'enable', 'disable'])
    parser.add_argument('--home', default=str(Path(__file__).resolve().parent))
    parser.add_argument('--entry', default=''); parser.add_argument('--exit', default='')
    args = parser.parse_args(); os.umask(0o077)
    try:
        if args.action == 'status':
            result = read_state(args.home)
            proxies, _, _ = parse_subscription(Path(args.home) / 'providers/nodes.yaml')
            result['names'] = [proxy['name'] for proxy in proxies if proxy['type'] not in ('direct', 'reject')]
        else:
            result = apply(args.home, args.action == 'enable', args.entry, args.exit)
        print(json.dumps(result, ensure_ascii=False)); return 0
    except Exception as error:
        detail = str(error) if isinstance(error, SubscriptionError) else '无法读取或应用链式配置。'
        print(json.dumps({'error': detail}, ensure_ascii=False)); return 1


if __name__ == '__main__': sys.exit(main())
