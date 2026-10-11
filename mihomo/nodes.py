#!/usr/bin/env python3
"""列出 mihomo 订阅 provider 中的节点及测速结果。
用法: nodes.py [provider名] [API地址]  默认: trojan-sub 127.0.0.1:9090
"""
import json
import os
import sys
import urllib.request


def t(zh, en):
    """提示语言：AMYFREE_LANG=en 输出英文，默认中文（菜单栏 App 按界面语言传入）。"""
    return en if os.environ.get('AMYFREE_LANG') == 'en' else zh

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
    print(t(f"✗ 无法获取 provider 数据: {e}", f"✗ Could not fetch provider data: {e}"))
    sys.exit(1)

proxies = data.get("proxies") or []
if not proxies:
    print(t("(订阅中没有任何节点 —— 检查订阅格式或链接是否有效)", "(The subscription has no nodes. Check its format or link.)"))
    sys.exit(1)

print(t(f"provider: {provider}   节点数: {len(proxies)}", f"provider: {provider}   nodes: {len(proxies)}"))
print("-" * 56)
alive = 0
for i, p in enumerate(proxies, 1):
    delay = t("未测速", "not tested")
    for h in reversed(p.get("history") or []):
        d = h.get("delay") or 0
        delay = f"{d} ms" if d > 0 else t("超时", "timeout")
        break
    ok = p.get("alive")
    if ok:
        alive += 1
    print(f"{i:3d}. [{'OK ' if ok else 'DEAD'}] {p.get('name', '?'):<34} {delay}")
print("-" * 56)
print(t(f"可用: {alive}/{len(proxies)}", f"Available: {alive}/{len(proxies)}"))
