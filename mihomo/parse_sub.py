#!/usr/bin/env python3
"""把 Clash YAML/JSON 或原始链接/base64 订阅转换成 mihomo 节点文件。

用法: parse_sub.py <订阅原始文件> <输出yaml> [mixed-port] [mode]

链接解析使用 Python 标准库；YAML 使用安全加载器，优先 PyYAML，回退到 macOS Ruby/Psych。
"""
import base64
import binascii
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.parse


class SubscriptionError(ValueError):
    pass


def t(zh, en):
    """提示语言：AMYFREE_LANG=en 输出英文，默认中文（菜单栏 App 按界面语言传入）。"""
    return en if os.environ.get('AMYFREE_LANG') == 'en' else zh


def load_yaml(text):
    """禁止任意对象构造；不在错误消息中回显订阅或节点凭据。"""
    try:
        import yaml
    except ImportError:
        ruby = '/usr/bin/ruby'
        if not os.path.isfile(ruby):
            raise SubscriptionError(t('此环境缺少安全 YAML 解析器，请安装 PyYAML 后重试。', 'No safe YAML parser is available here. Install PyYAML and try again.'))
        code = '''require "json"
require "psych"
begin
  text = STDIN.read
  if Psych.method(:safe_load).parameters.any? { |kind, name| [:key, :keyreq].include?(kind) && name == :aliases }
    value = Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: true)
  else
    value = Psych.safe_load(text, [], [], true)
  end
  STDOUT.write(JSON.generate(value))
rescue Exception
  STDERR.write("Invalid YAML")
  exit 1
end
'''
        try:
            result = subprocess.run([ruby, '-e', code], input=text, capture_output=True, text=True, timeout=15)
            if result.returncode:
                raise SubscriptionError(t('订阅 YAML 格式不正确或含不支持的对象。', 'The subscription YAML is malformed or contains unsupported objects.'))
            return json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            raise SubscriptionError(t('无法安全解析订阅 YAML。', 'Could not safely parse the subscription YAML.')) from None
    try:
        return yaml.safe_load(text)
    except Exception:
        raise SubscriptionError(t('订阅 YAML 格式不正确或含不支持的对象。', 'The subscription YAML is malformed or contains unsupported objects.')) from None


def plain_data(value, ancestors=None):
    """只接受有限、无循环的配置数据，保留字符串/数字/布尔类型。"""
    ancestors = set() if ancestors is None else ancestors
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float) and math.isfinite(value):
        return
    if isinstance(value, (dict, list)):
        if id(value) in ancestors:
            raise SubscriptionError(t('节点配置包含循环引用。', 'The node config contains a circular reference.'))
        ancestors.add(id(value))
        if isinstance(value, dict):
            if not all(isinstance(key, str) for key in value):
                raise SubscriptionError(t('节点配置字段名必须是字符串。', 'Node config field names must be strings.'))
            children = value.values()
        else:
            children = value
        for child in children:
            plain_data(child, ancestors)
        ancestors.remove(id(value))
        return
    raise SubscriptionError(t('节点配置包含不支持的数据类型。', 'The node config contains an unsupported data type.'))


def validate_proxies(proxies):
    if not isinstance(proxies, list) or not proxies:
        raise SubscriptionError(t('订阅中没有可用的 proxies 节点列表。', 'The subscription has no usable proxies list.'))
    plain_data(proxies)
    names = set()
    for index, proxy in enumerate(proxies, 1):
        if not isinstance(proxy, dict):
            raise SubscriptionError(t(f'第 {index} 个节点不是有效配置。', f'Node {index} is not a valid config.'))
        for key in ('name', 'type'):
            if not isinstance(proxy.get(key), str) or not proxy[key].strip():
                raise SubscriptionError(t(f'第 {index} 个节点缺少有效的 {key} 字段。', f'Node {index} is missing a valid {key} field.'))
        if proxy['name'] in names:
            raise SubscriptionError(t(f'第 {index} 个节点与前面的节点重名，请修正订阅。', f'Node {index} has the same name as an earlier node. Fix the subscription.'))
        names.add(proxy['name'])
        if proxy['type'] not in ('direct', 'reject'):
            if not isinstance(proxy.get('server'), str) or not proxy['server'].strip():
                raise SubscriptionError(t(f'第 {index} 个节点缺少服务器地址。', f'Node {index} is missing a server address.'))
            if isinstance(proxy.get('port'), bool) or not isinstance(proxy.get('port'), int) or not 1 <= proxy['port'] <= 65535:
                raise SubscriptionError(t(f'第 {index} 个节点端口不正确。', f'Node {index} has an invalid port.'))
    return proxies

# ---------------- 各类链接 -> Clash proxy ----------------

def _qs(u):
    return urllib.parse.parse_qs(u.query)


def parse_vless(line):
    u = urllib.parse.urlparse(line)
    q = _qs(u)
    p = {
        "name": urllib.parse.unquote(u.fragment) or "vless",
        "type": "vless",
        "server": u.hostname,
        "port": int(u.port),
        "uuid": u.username,
        "udp": True,
    }
    net = q.get("type", ["tcp"])[0]
    if net == "ws":
        p["network"] = "ws"
        opts = {}
        if q.get("path"):
            opts["path"] = urllib.parse.unquote(q["path"][0])
        if q.get("host"):
            opts["headers"] = {"Host": q["host"][0]}
        p["ws-opts"] = opts
    elif net == "grpc":
        p["network"] = "grpc"
        p["grpc-opts"] = {"grpc-service-name": q.get("serviceName", [""])[0]}
    else:
        p["network"] = "tcp"
    if q.get("security", ["none"])[0] == "tls":
        p["tls"] = True
        if q.get("sni", [""])[0]:
            p["servername"] = q["sni"][0]
        if q.get("fp"):
            p["client-fingerprint"] = q["fp"][0]
        if q.get("alpn"):
            p["alpn"] = urllib.parse.unquote(q["alpn"][0]).split(",")
    if q.get("flow", [""])[0]:
        p["flow"] = q["flow"][0]
    if q.get("security", [""])[0] == "reality":
        p["tls"] = True
        ro = {}
        if q.get("pbk"):
            ro["public-key"] = q["pbk"][0]
        if q.get("sid"):
            ro["short-id"] = q["sid"][0]
        if ro:
            p["reality-opts"] = ro
        if q.get("sni"):
            p["servername"] = q["sni"][0]
    return p


def parse_trojan(line):
    u = urllib.parse.urlparse(line)
    q = _qs(u)
    p = {
        "name": urllib.parse.unquote(u.fragment) or "trojan",
        "type": "trojan",
        "server": u.hostname,
        "port": int(u.port),
        "password": urllib.parse.unquote(u.username or ""),
        "udp": True,
        "skip-cert-verify": q.get("allowInsecure", ["0"])[0] == "1",
    }
    if q.get("sni"):
        p["sni"] = q["sni"][0]
    elif q.get("peer"):
        p["sni"] = q["peer"][0]
    if q.get("type", [""])[0] == "ws":
        p["network"] = "ws"
        opts = {}
        if q.get("path"):
            opts["path"] = urllib.parse.unquote(q["path"][0])
        if q.get("host"):
            opts["headers"] = {"Host": q["host"][0]}
        p["ws-opts"] = opts
    if q.get("alpn"):
        p["alpn"] = urllib.parse.unquote(q["alpn"][0]).split(",")
    return p


def parse_ss(line):
    body = line[5:].split("#")[0]
    name = urllib.parse.unquote(line.split("#", 1)[1]) if "#" in line else "ss"
    if "@" in body:
        userpart, hostpart = body.rsplit("@", 1)
        try:
            dec = base64.b64decode(userpart + "=" * (-len(userpart) % 4)).decode()
        except Exception:
            dec = urllib.parse.unquote(userpart)
        method, _, pwd = dec.partition(":")
        host, _, port = hostpart.rpartition(":")
        return {"name": name, "type": "ss", "server": host,
                "port": int(port), "cipher": method, "password": pwd, "udp": True}
    dec = base64.b64decode(body + "=" * (-len(body) % 4)).decode("utf-8", "replace")
    m = re.match(r"([^:]+):([^@]+)@([^:]+):(\d+)", dec)
    if not m:
        raise ValueError(t("无法解析 Shadowsocks 链接", "Could not parse the Shadowsocks link"))
    method, pwd, host, port = m.groups()
    return {"name": name, "type": "ss", "server": host,
            "port": int(port), "cipher": method, "password": pwd, "udp": True}


def parse_vmess(line):
    body = line[8:].split("#")[0]
    d = json.loads(base64.b64decode(body + "=" * (-len(body) % 4)).decode("utf-8", "replace"))
    p = {"name": d.get("ps") or "vmess", "type": "vmess",
         "server": d["add"], "port": int(d["port"]),
         "uuid": d["id"], "alterId": int(d.get("aid", 0) or 0),
         "cipher": d.get("scy", "auto") or "auto", "udp": True}
    if str(d.get("tls", "")).lower() in ("tls", "true", "1"):
        p["tls"] = True
    if d.get("sni"):
        p["servername"] = d["sni"]
    net = d.get("net", "tcp")
    if net == "ws":
        p["network"] = "ws"
        opts = {"path": d.get("path", "/")}
        if d.get("host"):
            opts["headers"] = {"Host": d["host"]}
        p["ws-opts"] = opts
    return p


PARSERS = {"vless": parse_vless, "trojan": parse_trojan, "ss": parse_ss, "vmess": parse_vmess}


def decode_subscription(path):
    """返回 (链接列表, 原始形态描述)"""
    raw = Path(path).read_bytes()
    txt = raw.decode("utf-8-sig", "replace").strip()
    schemes = ("vless://", "trojan://", "vmess://", "ss://", "hysteria2://", "tuic://")
    if any(line.strip().startswith(schemes) for line in txt.splitlines()):
        return [l.strip() for l in txt.splitlines() if l.strip()], t("明文链接", "Plain links")
    def decode(value):
        compact = re.sub(r"\s+", "", value)
        return base64.b64decode(compact + "=" * (-len(compact) % 4), altchars=b'-_', validate=True).decode('utf-8')
    try:
        dec = decode(txt)
    except (ValueError, UnicodeError, binascii.Error):
        dec = ''
    # 有些订阅是「每行一个 base64」，需要逐行解
    if not any(s in dec for s in schemes):
        outs = []
        for ln in txt.splitlines():
            ln = ln.strip()
            if not ln:
                continue
            try:
                outs.append(decode(ln).strip())
            except Exception:
                pass
        if any(s in "".join(outs) for s in schemes):
            return outs, t("逐行 base64", "Line-by-line base64")
    if not any(line.strip().startswith(schemes) for line in dec.splitlines()):
        raise SubscriptionError(t('返回内容不是有效的 Clash 配置或节点链接订阅，请检查地址是否返回网页或错误信息。', 'The response is not a valid Clash config or link subscription. Check whether the URL returns a web page or an error.'))
    return [l.strip() for l in dec.splitlines() if l.strip()], t("整块 base64", "Base64 block")


def parse_subscription(path):
    raw = Path(path).read_bytes()
    if not raw or len(raw) > 16 * 1024 * 1024:
        raise SubscriptionError(t('订阅为空或超过 16 MB 限制。', 'The subscription is empty or over the 16 MB limit.'))
    text = raw.decode('utf-8-sig', 'replace').strip()
    if text.startswith(('{', '[')) or re.search(r'''(?m)^["']?proxies["']?\s*:''', text):
        try:
            data = json.loads(text)
            form = 'Clash JSON'
        except json.JSONDecodeError:
            data = load_yaml(text)
            form = 'Clash YAML'
        if not isinstance(data, dict):
            raise SubscriptionError(t('Clash 订阅必须包含 proxies 节点列表。', 'A Clash subscription must include a proxies list.'))
        # 只导入节点，保留用户已有的分流、DNS、端口和策略组配置。
        return validate_proxies(data.get('proxies')), form, []
    lines, form = decode_subscription(path)
    proxies, failures = [], []
    for index, line in enumerate(lines, 1):
        if line.startswith('#'):
            continue
        scheme = line.split('://', 1)[0].lower() if '://' in line else ''
        parser = PARSERS.get(scheme)
        if parser is None:
            failures.append(t(f'第 {index} 行：不支持的节点协议', f'Line {index}: unsupported protocol'))
            continue
        try:
            proxies.append(parser(line))
        except Exception:
            failures.append(t(f'第 {index} 行：节点链接格式不正确', f'Line {index}: malformed node link'))
    return validate_proxies(proxies), form, failures


def to_yaml(cfg, indent=0):
    """类型安全的最小 YAML 输出。"""
    pad = " " * indent
    out = []
    for k, v in cfg.items():
        k = k if re.fullmatch(r'[A-Za-z0-9_-]+', k) else json.dumps(k, ensure_ascii=False)
        if isinstance(v, dict):
            out.append(f"{pad}{k}:")
            out.append(to_yaml(v, indent + 2))
        elif isinstance(v, list):
            if not v:
                out.append(f"{pad}{k}: []")
            elif all(isinstance(i, (str, int, float)) for i in v) and not any(
                    isinstance(i, str) and (":" in i or i.startswith(("-", "[", "{"))) for i in v):
                items = ", ".join(json.dumps(i, ensure_ascii=False, allow_nan=False) for i in v)
                out.append(f"{pad}{k}: [{items}]")
            else:
                out.append(f"{pad}{k}:")
                for item in v:
                    sub = to_yaml(item, indent + 4) if isinstance(item, dict) else None
                    if sub is None:
                        out.append(f"{pad}  - {json.dumps(item, ensure_ascii=False, allow_nan=False)}")
                    else:
                        # 把第一行挂到 "- " 上
                        lines = sub.splitlines()
                        first = lines[0].strip()
                        out.append(f"{pad}  - {first}")
                        out.extend(lines[1:])
        elif isinstance(v, bool):
            out.append(f"{pad}{k}: {'true' if v else 'false'}")
        elif v is None:
            out.append(f"{pad}{k}: null")
        elif isinstance(v, (int, float)):
            out.append(f"{pad}{k}: {v}")
        else:
            s = str(v).replace("\\", "\\\\").replace('"', '\\"')
            out.append(f'{pad}{k}: "{s}"')
    return "\n".join(out)


def main():
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    pos = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(pos) < 2:
        print(__doc__)
        sys.exit(1)
    sub_path, out_path = pos[0], pos[1]
    port = int(pos[2]) if len(pos) > 2 else 7890
    mode = pos[3] if len(pos) > 3 else "global"
    nodes_only = "--nodes-only" in flags

    try:
        proxies, form, failed = parse_subscription(sub_path)
    except (SubscriptionError, OSError, RecursionError) as error:
        detail = str(error) if isinstance(error, SubscriptionError) else t('无法读取或解析订阅文件。', 'Could not read or parse the subscription file.')
        print(f'✗ {detail}', file=sys.stderr)
        return 1
    print(t(f"订阅形态: {form}", f"Subscription format: {form}"))
    print(t(f"✓ 解析成功 {len(proxies)} 个节点", f"✓ Parsed {len(proxies)} nodes"))
    if failed:
        print(t(f"解析失败 {len(failed)} 条:", f"{len(failed)} failed to parse:"))
        for error in failed:
            print(f"  ! {error}")

    if nodes_only:
        # 供 mihomo 作为 type: file 的 proxy-provider 使用
        body = to_yaml({"proxies": proxies})
    else:
        body = to_yaml({
            "mixed-port": port,
            "allow-lan": False,
            "mode": mode,
            "log-level": "info",
            "proxies": proxies,
            "rules": ["MATCH,GLOBAL"],
        })
    target = Path(out_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=target.parent, prefix='.nodes-', delete=False) as file:
            temporary = Path(file.name)
            file.write(body + '\n')
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    print(t(f"✓ 节点文件已生成（{len(proxies)} 节点）", f"✓ Node file written ({len(proxies)} nodes)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
