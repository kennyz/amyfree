# Gotchas：踩过的坑与不可想当然的结论

这个文件记录开发过程中**实际验证过**的非显然结论。每条都标注了证据，改动相关代码前请先读。

---

## 1. DNS：`direct-nameserver` 缺了会死锁 ★最坑

**症状**：内核启动后 provider 拉取失败，日志出现

```
initial proxy provider nodes error: Get "https://<订阅域名>": net/http: TLS handshake timeout
[TCP] dial PROXY --> <订阅域名>:2096 error: dns resolve failed: context deadline exceeded
```

**根因**：开启 `respect-rules: true` 后，DNS 查询被当作普通流量走规则 → 解析「订阅/节点域名」需要先连上代理 → 而连代理又需要先解析域名。**鸡生蛋死锁**。

**解决**：`dns.direct-nameserver` 必须配置，它专门负责在直连路径上解析这些域名。

**验证过程**：
- `respect-rules: false` + 纯 UDP `nameserver` → **仍然失败**
- 只有加上 `direct-nameserver` 之后 provider 才成功下载

---

## 2. 不要用 1.1.1.1 / 8.8.8.8 的 DoH

**实测**：开发环境所在网络**丢弃这两个 IP 的 443 端口**。

```
curl https://1.1.1.1  → connection refused / 超时
```

所以 `dns.fallback` 里写 `https://1.1.1.1/dns-query` 会导致 DNS 整体不可用（日志里表现为 `all DNS requests failed`）。

**改用**：纯 UDP 的国内 DNS（`223.5.5.5`、`119.29.29.29`、`114.114.114.114`）。

---

## 3. `respect-rules: true` 会把国内 DNS 也塞进代理

**实测日志**：

```
[TCP] dial PROXY (match GeoSite/geolocation-!cn) --> www.google.com:443
         error: dns resolve failed: requesting https://1.1.1.1:443/dns-query: context deadline exceeded
```

开着 `respect-rules` 时，连 DNS 查询本身都按规则走代理，国内解析也会被绕进代理，反而更慢更容易超时。

**当前配置取 `false`**，并靠 `sniffer` 把真实域名还原出来交给节点远端解析。

---

## 4. `geo-auto-update` 必须为 false

**实测**：工作目录缺少 `country.mmdb` 时，mihomo 会去 GitHub 下载并**无限期卡住**，表现为启动后长时间无响应，且没有任何超时提示。

**解决**：
- `geo-auto-update: false`
- 三个规则库文件（`geoip.dat` / `geosite.dat` / `country.mmdb`）**必须预置在工作目录**
- 更新走 `scripts/refresh-geodata.sh`（jsDelivr 镜像）

---

## 5. base64 订阅：mihomo 不能直读，必须先转换

**实测**：机场订阅返回的是

```
dmxlc3M6Ly8wMzljNzA1NS0...（整块 base64）
```

解码后是 `vless://...` 原始链接列表。mihomo 的 `proxy-providers` **不支持**这种格式。

**解决**：`parse_sub.py` 负责「base64 解码 → 解析各协议 → 生成 Clash YAML」，然后以
`type: file` 的 provider 加载 `providers/nodes.yaml`。

**注意**：`proxy-providers` 的本地缓存**优先于**订阅 URL。所以换订阅后必须
**删除 `providers/*.yaml` 并重启**，只做 API 热重载不会重新拉取订阅——这个坑实际导致过
「换了订阅地址但仍在用旧节点」。

---

## 6. 一个假象：`ss://` 计数

排查订阅格式时，用 `grep -c 'ss://'` 数出 1 个 ss 节点，但订阅里其实**没有** ss 节点。

**原因**：节点域名里恰好包含子串 `ss://`（例如 `exa**ss**le.example.com` 中的字符序列
`ss` 紧跟后面的 `.example...` 被跨字段误匹配），因此 `contains` 判断会误报。

**正确做法**：判断协议要用**行首匹配**（`line.startswith('ss://')`），不要用 `contains`。
项目里的 `parse_sub.py` 用的是行首 `scheme://` 拆分，因此不受影响。

---

## 7. `curl` 不读 macOS 系统代理

**实测**：用 `networksetup` 设好系统代理后，

```
python3 urllib.getproxies()  → {'http': 'http://127.0.0.1:7890', 'https': ...}   ✓ 读到了
curl https://www.google.com  → 超时（25s）                                        ✗ 没读到
```

**结论**：**不能用 `curl` 验证系统代理是否生效**，那验证的是「直连是否可达」。
curl 只认 `http_proxy` 等环境变量或显式 `-x`。

**验证系统代理的正确方式**：
```bash
scutil --proxy | grep -i enable
python3 -c "import urllib.request; print(urllib.request.getproxies())"
```
或者直接看浏览器。

---

## 8. TUN 模式必须 root，且在受限沙箱里会失败

**实测**（非 root 运行，utun 创建）：

```
Start TUN listening error: configure tun interface: Connect: operation not permitted
```

注意是 `operation not permitted` 而**不是** `permission denied` —— 这类错误通常意味着被安全
策略（沙箱）拦截，而不是单纯的权限位问题。

**结论**：TUN 需要 `sudo`。菜单栏里通过 `osascript ... with administrator privileges` 提权调用
`tun.sh`。

---

## 9. 非 root 无法监听 80 / 443

**实测**：
```
listen tcp 127.0.0.1:80:  bind: permission denied
listen tcp 127.0.0.1:443: bind: permission denied
listen tcp 127.0.0.1:7890: OK
listen tcp 127.0.0.1:1080: OK
```

所以 `mixed-port` 用 7890（也正好是 Clash 生态惯例，且是 macOS 系统代理常用端口）。

---

## 10. 脚本里的全角标点会污染变量名

**实测**：`grn "...（指向 $PROXY_PORT）"` 在 `set -u` 下报

```
PROXY_PORT）: unbound variable
```

**原因**：bash 把全角右括号 `）` 当成了变量名的一部分。

**规则**：变量后紧跟非 ASCII 字符时，一律写成 `${VAR}`。

（打包前已全仓库扫描确认无同类问题。）

---

## 11. 已编译二进制请勿手工 `cp` 后直接跑

`codesign` 会修改 Mach-O，所以：

- 源文件与 bundle 内二进制的 **SHA256 必然不同**（不是没编译成功）
- `cp -R` 之后建议重新 `codesign --force --deep --sign -`，并 `xattr -dr com.apple.quarantine`

**排查「改没改上」的正确方式**：往源码里插一个 ASCII 标记字符串再编译，然后
`grep -a 标记 二进制`。中文 UTF-8 字面量用 `grep -a` 搜不到（会被编码处理），不要以此判断。

---

## 12. `swiftc` 默认缓存目录可能不可写

`swiftc` 默认把模块缓存写到 `~/Library/Developer/...`。在受限环境下会失败。

**解决**：显式指定
```bash
swiftc -O app/*.swift -o build/Amyfree \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" \
  -target arm64-apple-macosx13.0 -framework AppKit -framework ServiceManagement
```

---

## 13. 常见 API 端点位置（排查时常用）

| 用途 | 端点 |
|---|---|
| 版本 | `GET /version` |
| 策略组当前选中 | `GET /proxies/<组名>`（字段 `now`） |
| **provider 节点列表** | `GET /providers/proxies/<provider名>` |
| 快速测速 | `GET /proxies/<节点名>/delay?timeout=15000&url=...` |

**注意**：节点列表在 `/providers/proxies/...`，**不是** `/proxies/<provider名>`
（后者会返回 `{"message":"Resource not found"}`）。这个错误曾导致菜单栏节点列表恒为空。

**中文组名**：`/proxies/手动选择` 原样传也能用（mihomo 两种都接受），但 URL 编码更稳妥。

**鉴权**：设了 `secret` 后，请求需带 `Authorization: Bearer <secret>`，否则 401。

---

## 14. `proxy-providers` 的 `exclude-filter` 会误伤

按关键词过滤「到期/流量/官网」等条目时要注意：不同机场的命名差异很大，过滤规则写太宽
会把正常节点也滤掉。排查「节点数量不对」时先把它注释掉。

---

## 15. `curl` 取出口 IP 必须加 `-L`

**实测**：`http://1.1.1.1/cdn-cgi/trace` 会返回 **301**。不加 `-L` 时拿到的是重定向页面，
`grep '^ip='` 自然什么都匹配不到，于是 `verify_node.sh` **误报「节点未生效」**——
而同一时刻 `https://www.google.com`、`github.com`、`youtube.com` 全部返回 200。

这个误报非常有迷惑性：功能明明是好的，验证脚本却报失败。
**规则**：所有用于取出口 IP / trace 的 curl 都加 `-L`。

---

## 16. 端口被占用时实例会「起来但完全不工作」

**实测场景**：`~/.config/mihomo` 的实例已占着 7890/9090，此时从另一个目录再启动一个
mihomo，进程能起来、日志也显示 "Mixed proxy listening"，但：

- API 请求返回 **401 Unauthorized**（连的其实是旧实例，secret 不同）
- 出口 IP 判定结果错乱

**极难排查**，因为表面上一切正常。

**已加防护**：`mihomoctl.sh start` 在启动前检查 7890/9090 是否被占用，占用则明确报错并列出
占用进程，而不是静默启动一个废实例。

**排查手段**：
```bash
lsof -nP -iTCP:9090 -sTCP:LISTEN     # 谁占着 API 端口
lsof -nP -iTCP:7890 -sTCP:LISTEN     # 谁占着代理端口
pgrep -fl "mihomo -d"                # 总共几个实例
```
