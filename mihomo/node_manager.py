#!/usr/bin/env python3
"""节点管理：手工添加节点、编辑现有节点；更新订阅后仍保留。

订阅原始节点保存在 providers/subscription.yaml，手工改动保存在 custom-nodes.json，
两者合并后写入内核加载的 providers/nodes.yaml。
"""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import urllib.request

from parse_sub import PARSERS, SubscriptionError, load_yaml, parse_subscription, plain_data, t, to_yaml, validate_proxies
from subscription import SubscriptionManager, atomic_write


def store_path(directory):
    return Path(directory) / 'custom-nodes.json'


def read_store(directory):
    path = store_path(directory)
    if not path.exists():
        return {'added': [], 'edited': {}}
    value = json.loads(path.read_text())
    return {'added': list(value.get('added') or []), 'edited': dict(value.get('edited') or {})}


def merge(base, store):
    """订阅节点按原名套用编辑，再追加手工节点；重名时保留先出现的，返回 (节点, 被跳过的名称)。"""
    merged, names, skipped = [], set(), []
    for proxy in [store['edited'].get(proxy['name'], proxy) for proxy in base] + store['added']:
        if proxy['name'] in names:
            skipped.append(proxy['name']); continue
        names.add(proxy['name']); merged.append(proxy)
    return merged, skipped


def merge_custom(directory, base):
    """更新订阅时调用：没有手工改动时原样返回。"""
    merged, skipped = merge(base, read_store(directory))
    if skipped:
        print(t('! 以下自定义节点与订阅节点重名，本次未加载：', '! These custom nodes share a name with subscription nodes and were not loaded: ')
              + '、'.join(skipped), flush=True)
    return merged


def read_base(directory):
    directory = Path(directory)
    for path in (directory / 'providers/subscription.yaml', directory / 'providers/nodes.yaml'):
        if path.exists():
            # 升级前只有 nodes.yaml；首次编辑前它就是订阅原样。
            return parse_subscription(path)[0]
    return []


def origin(store, base, name):
    """返回 (类型, 键)：added 以当前名称为键，edited/subscription 以订阅原名为键。"""
    if any(proxy['name'] == name for proxy in store['added']):
        return 'added', name
    for proxy in base:
        if store['edited'].get(proxy['name'], proxy)['name'] == name:
            return ('edited' if proxy['name'] in store['edited'] else 'subscription'), proxy['name']
    raise SubscriptionError(t('节点已不存在，请重新打开节点管理。', 'The node no longer exists. Reopen Node Management.'))


# 表单提交的 JSON 没有字段顺序，按常用顺序排列，源码视图更易读。
FIELD_ORDER = ['name', 'type', 'server', 'port', 'cipher', 'uuid', 'alterId', 'username', 'password', 'flow',
               'tls', 'servername', 'sni', 'skip-cert-verify', 'network', 'ws-opts', 'grpc-opts', 'udp']


def ordered(proxy):
    return {**{key: proxy[key] for key in FIELD_ORDER if key in proxy},
            **{key: value for key, value in proxy.items() if key not in FIELD_ORDER}}


def parse_node(text, strict=True):
    """接受一条分享链接，或单个节点的 Clash YAML/JSON；strict=False 用于表单/源码互转，允许未填完。"""
    text = text.strip()
    if not text and not strict:
        return {}
    if not text:
        raise SubscriptionError(t('请粘贴节点链接或节点配置。', 'Paste a node link or node config.'))
    scheme = text.split('://', 1)[0].lower() if '://' in text.splitlines()[0] else ''
    if scheme in PARSERS:
        if len(text.splitlines()) > 1:
            raise SubscriptionError(t('一次只能添加一个节点链接。', 'Add one node link at a time.'))
        try:
            proxy = PARSERS[scheme](text)
        except Exception:
            raise SubscriptionError(t('节点链接格式不正确。', 'The node link is malformed.')) from None
    else:
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            value = load_yaml(text)
        if isinstance(value, dict) and isinstance(value.get('proxies'), list):
            value = value['proxies']
        if isinstance(value, list):
            if len(value) != 1:
                raise SubscriptionError(t('一次只能保存一个节点。', 'Save one node at a time.'))
            value = value[0]
        if not isinstance(value, dict):
            raise SubscriptionError(t('无法识别节点配置，请使用 vless/vmess/ss/trojan 链接或 Clash 节点 YAML。', 'Unrecognised node config. Use a vless/vmess/ss/trojan link or Clash node YAML.'))
        proxy = ordered(value) if text.startswith('{') else value
    if not strict:
        plain_data(proxy)
        return proxy
    validate_proxies([proxy])
    if proxy['type'] in ('direct', 'reject'):
        raise SubscriptionError(t('请填写实际代理节点。', 'Enter a real proxy node.'))
    return proxy


def api_request(directory, method, path, body=None):
    secret = (Path(directory) / '.api-secret').read_text().strip()
    api = os.environ.get('MIHOMO_API', '127.0.0.1:9090')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(f'http://{api}{path}', method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/json'})
    with opener.open(request, timeout=12) as response:
        return response.read()


def reload(directory, merged, config_changed):
    if config_changed:
        api_request(directory, 'PUT', '/configs?force=true', {'path': str(Path(directory) / '.run-config.yaml')})
    else:
        api_request(directory, 'PUT', '/providers/proxies/nodes')
    loaded = json.loads(api_request(directory, 'GET', '/providers/proxies/nodes')).get('proxies', [])
    if [proxy.get('name') for proxy in loaded] != [proxy['name'] for proxy in merged]:
        raise SubscriptionError(t('内核未能加载更新后的节点列表。', 'The core did not load the updated node list.'))


def commit(directory, base, store):
    """校验并写入合并结果；运行中即时重载，失败恢复全部文件。"""
    from chain_proxy import running, subscription_updates
    directory = Path(directory)
    merged, skipped = merge(base, store)
    if skipped:
        raise SubscriptionError(t(f'节点名称「{skipped[0]}」已存在，请换一个名称。', f'A node named "{skipped[0]}" already exists. Choose another name.'))
    manager = SubscriptionManager(directory)
    with tempfile.TemporaryDirectory(prefix='.node-validate-', dir=directory) as temporary, contextlib.redirect_stdout(io.StringIO()):
        manager.validate(merged, Path(temporary))
    chain_changes = subscription_updates(directory, merged)
    updates = {directory / 'providers/subscription.yaml': (to_yaml({'proxies': base}) + '\n').encode('utf-8'),
               manager.nodes_file: (to_yaml({'proxies': merged}) + '\n').encode('utf-8'),
               store_path(directory): json.dumps(store, ensure_ascii=False, indent=2).encode('utf-8')}
    updates.update(chain_changes)
    active = running(directory)
    if not active:
        # 内核停止时运行配置会在下次启动时重新生成。
        updates.pop(directory / '.run-config.yaml', None)
    snapshots = {path: path.read_bytes() if path.exists() else None for path in updates}
    try:
        for path, content in updates.items():
            atomic_write(path, content)
        if active:
            reload(directory, merged, bool(chain_changes))
    except Exception:
        for path, content in snapshots.items():
            if content is None: path.unlink(missing_ok=True)
            else: atomic_write(path, content)
        if active:
            try: reload(directory, merge(base, read_store(directory))[0], bool(chain_changes))
            except Exception: raise SubscriptionError(t('保存失败，文件已恢复，但内核还原失败，请重新启动代理。', 'Save failed. The files were restored, but restoring the core failed. Restart the proxy.')) from None
        raise SubscriptionError(t('节点修改未生效，已恢复原配置。', 'The node change did not take effect; the previous config was restored.')) from None
    return active


def status(directory):
    store, base = read_store(directory), read_base(directory)
    merged, _ = merge(base, store)
    return {'nodes': [{'name': proxy['name'], 'origin': origin(store, base, proxy['name'])[0]} for proxy in merged]}


def get(directory, name):
    store, base = read_store(directory), read_base(directory)
    kind, key = origin(store, base, name)
    proxy = next(proxy for proxy in merge(base, store)[0] if proxy['name'] == name)
    return {'name': name, 'origin': kind, 'node': proxy, 'config': to_yaml(proxy) + '\n'}


def save(directory, original, text):
    store, base = read_store(directory), read_base(directory)
    proxy = parse_node(text)
    if not original:
        store['added'].append(proxy)
    else:
        kind, key = origin(store, base, original)
        if kind == 'added':
            store['added'] = [proxy if item['name'] == key else item for item in store['added']]
        elif proxy == next(item for item in base if item['name'] == key):
            store['edited'].pop(key, None)
        else:
            store['edited'][key] = proxy
    return {'name': proxy['name'], 'applied': commit(directory, base, store)}


def delete(directory, name):
    store, base = read_store(directory), read_base(directory)
    kind, key = origin(store, base, name)
    if kind == 'subscription':
        raise SubscriptionError(t('订阅节点不能删除，更新订阅时会重新出现。', 'Subscription nodes cannot be deleted; they return when the subscription updates.'))
    if kind == 'added':
        store['added'] = [item for item in store['added'] if item['name'] != key]
    else:
        store['edited'].pop(key)
    return {'name': name, 'origin': kind, 'applied': commit(directory, base, store)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'get', 'parse', 'save', 'delete'])
    parser.add_argument('--home', default=str(Path(__file__).resolve().parent))
    parser.add_argument('--name', default='')
    args = parser.parse_args(); os.umask(0o077)
    try:
        if args.action == 'status': result = status(args.home)
        elif args.action == 'get': result = get(args.home, args.name)
        elif args.action == 'parse':
            proxy = parse_node(sys.stdin.read(), strict=False)
            result = {'node': proxy, 'config': to_yaml(proxy) + '\n' if proxy else ''}
        elif args.action == 'save': result = save(args.home, args.name, sys.stdin.read())
        else: result = delete(args.home, args.name)
        print(json.dumps(result, ensure_ascii=False)); return 0
    except Exception as error:
        # 节点配置含凭据；仅输出明确的用户提示。
        detail = str(error) if isinstance(error, SubscriptionError) else t('无法读取或保存节点配置。', 'Could not read or save the node config.')
        print(json.dumps({'error': detail}, ensure_ascii=False)); return 1


if __name__ == '__main__': sys.exit(main())
