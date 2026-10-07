#!/usr/bin/env python3
"""列出 mihomo 订阅 provider 中的节点及测速结果。
用法: nodes.py [provider名] [API地址]  默认: trojan-sub 127.0.0.1:9090
"""
import json
import sys
import urllib.request

provider = sys.argv[1] if len(sys.argv) > 1 else "trojan-sub"
api = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:9090"
secret = sys.argv[3] if len(sys.argv) > 3 else ""

url = f"http://{api}/providers/proxies/{provider}"
req = urllib.request.Request(url)
if secret:
    req.add_header("Authorization", f"Bearer {secret}")
try:
    with urllib.request.urlopen(req, timeout=6) as r:
        data = json.load(r)
except Exception as e:
    print(f"✗ 无法获取 provider 数据: {e}")
    sys.exit(1)

proxies = data.get("proxies") or []
if not proxies:
    print("(订阅中没有任何节点 —— 检查订阅格式或链接是否有效)")
    sys.exit(1)

print(f"provider: {provider}   节点数: {len(proxies)}")
print("-" * 56)
alive = 0
for i, p in enumerate(proxies, 1):
    delay = "未测速"
    for h in reversed(p.get("history") or []):
        d = h.get("delay") or 0
        delay = f"{d} ms" if d > 0 else "超时"
        break
    ok = p.get("alive")
    if ok:
        alive += 1
    print(f"{i:3d}. [{'OK ' if ok else 'DEAD'}] {p.get('name', '?'):<34} {delay}")
print("-" * 56)
print(f"可用: {alive}/{len(proxies)}")
