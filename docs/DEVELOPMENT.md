# Amyfree 开发文档

源码开发参考。下载与日常使用请见 [项目首页](../README.md)。

一个 macOS 上的代理方案：**mihomo (Clash.Meta) 内核** + **纯 AppKit 菜单栏控制面板**。

- 无第三方依赖，不需要 Xcode 工程（原生 Swift / AppKit，`swiftc` 直接编译）
- 订阅兼容性好：支持机场常见的 **base64 编码原始链接**订阅（vless/vmess/ss/trojan）
- 支持完整 Clash YAML/JSON 订阅；只导入节点，不覆盖已有的分流和 DNS 设置
- 一键开关：启动内核时自动接管 macOS 系统代理，浏览器即可用
- 可选 TUN 全局接管
- 菜单「关于 Amyfree」可查看应用版本和已安装的 mihomo 内核版本（内核停止时也可查看）
- 自带蓝绿色盾牌应用图标，构建时自动生成完整 macOS 图标尺寸
- 原生可视化分流设置：国内直连、广告拦截、网站和 IP 网段规则；保存检查、即时生效与回退
- 节点状态图标，每 30 秒自动检测延迟与可用性，支持手工实际下载测速
- 两跳链式代理：选择入口、出口，保存校验、即时重载和关闭恢复
- 精简的两级菜单；节点测速同步显示 TLS 证书有效期和到期提醒

---

## 快速开始

菜单栏 App（M 系列 Mac，需 Xcode Command Line Tools）：

```bash
bash scripts/build-app.sh            # 编译打包到 build/
bash scripts/install-menubar.sh      # 自动准备内核/规则库，装到 ~/Applications 并启动
```

源码构建的 App 不内置内核；安装脚本会自动补齐 `~/.config/mihomo` 中的内核、规则库和运行脚本，并保留已有订阅、密钥与配置。首次使用从菜单导入订阅即可。直接双击 `build/Amyfree.app` 前应先执行安装脚本。

单独修复运行依赖：`bash scripts/install-source-runtime.sh`。

仅命令行调试可按下面步骤操作；不要与菜单栏安装同时启动两个内核：

```bash
# 1. 拉取依赖（内核 + 规则库 + 配置文件）
bash scripts/fetch-deps.sh

# 2. 设置订阅地址（务必用单引号，URL 里常含 &）
./mihomo/mihomoctl.sh sub 'https://your-provider/subs/token'

# 3. 启动并验证
cd mihomo && ./mihomoctl.sh start && ./mihomoctl.sh verify && cd ..

# 4. 让浏览器也走代理
./mihomo/proxyctl.sh on
```

需要独立内核 LaunchAgent 的高级用法仍可使用 `bash scripts/install-mihomo.sh`，普通菜单栏安装无需此步骤。

---

## 目录结构

```
.
├── app/                        菜单栏 App（Swift / AppKit，无第三方依赖）
│   ├── main.swift              菜单构建、状态轮询、动作分发
│   ├── RoutingModel.swift      规则模型、输入校验与配置保存事务
│   ├── RoutingRules.swift      可视化分流窗口与内核热重载
│   ├── LoginStartup.swift      macOS 登录自启登记、状态读回与失败处理
│   ├── NodeProbeModel.swift    30 秒检测调度与测速状态
│   ├── NodeProbeClient.swift   后台测速组件调用与取消
│   ├── NodeProbeWindow.swift   节点测速与链式设置窗口
│   └── Info.plist              LSUIElement=true（只驻留菜单栏，不占 Dock）
├── mihomo/                     运行时（脚本 + 配置模板，依赖由 fetch-deps.sh 拉取）
│   ├── mihomoctl.sh            内核管理：start/stop/restart/status/sub/refresh/nodes/verify/env
│   ├── proxyctl.sh             macOS 系统代理开关：on/off/status/refresh
│   ├── tun.sh                  TUN 全局接管开关（需 sudo）
│   ├── verify_node.sh          节点连通性硬验证（出口 IP 必须变化）
│   ├── parse_sub.py            base64 订阅 → Clash YAML 转换器（核心）
│   ├── subscription.py         订阅测试、节点校验、更新和失败回退
│   ├── node_speed.py           隔离会话的延迟检测与实际下载测速
│   ├── chain_proxy.py          两跳链式配置、重载与失败回退
│   ├── cert_probe.py           TLS 证书有效期、信任状态和链式汇总
│   ├── nodes.py                节点列表与延迟展示
│   └── config.template.yaml    配置模板（安装时生成 config.yaml）
├── scripts/
│   ├── fetch-deps.sh           下载内核与规则库（走国内可达镜像）
│   ├── refresh-geodata.sh      手动更新 GeoIP/GeoSite/MMDB（带回滚）
│   ├── build-app.sh            编译打包菜单栏 App
│   ├── generate-icon.swift     用 AppKit 绘制各尺寸应用图标
│   ├── test-routing.sh         分流规则与保存回退测试
│   ├── test-startup.sh         自启开关与错误反馈回归测试
│   ├── install-mihomo.sh       安装运行时 + LaunchAgent
│   └── install-menubar.sh      安装菜单栏 App
└── docs/GOTCHAS.md             ★ 踩坑记录，改代码前先读
```

---

## 架构要点

### 数据流

```
订阅 URL ──curl──> .sub-raw ──parse_sub.py──> providers/nodes.yaml
                                                    │
                                         mihomo 以 type:file 加载
                                                    │
                                            ┌───────┴───────┐
                                      mixed-port:7890   API:9090
                                            │               │
                                    系统代理/浏览器    菜单栏轮询状态
```

**为什么 provider 用 `type: file` 而不是 `type: http`**：机场订阅多为 base64 编码的原始
链接列表，mihomo 读不了，必须先转换。详见 `docs/GOTCHAS.md` 第 5 条。

### 菜单栏状态刷新

每 5 秒轮询一次，网络查询（出口 IP、节点延迟、系统代理状态）全部放在**后台队列**，
避免阻塞主线程导致菜单卡顿。内核未运行时跳过网络查询。

### 环境变量

| 变量 | 作用 |
|---|---|
| `MIHOMO_HOME` | 覆盖配置目录（默认 `~/.config/mihomo`）。本地调试用，避免污染真实配置 |
| `MIHOMO_VERSION` | `fetch-deps.sh` 下载的内核版本（默认 `v1.19.32`） |
| `GH_MIRROR` | GitHub 镜像前缀（默认 `https://gh-proxy.com/`） |
| `GEODATA_BASE` | 规则库下载源（默认 jsDelivr） |

本地调试菜单栏：

```bash
bash scripts/fetch-deps.sh
MIHOMO_HOME="$PWD/mihomo" build/Amyfree.app/Contents/MacOS/Amyfree
```

---

## 常用命令

```bash
cd mihomo

./mihomoctl.sh start            # 启动内核
./mihomoctl.sh stop             # 停止
./mihomoctl.sh status           # 状态 + 端口监听
./mihomoctl.sh restart
./mihomoctl.sh sub '<URL>'      # 设置订阅地址（自动拉取+转换+重启）
./mihomoctl.sh sub              # 查看当前订阅地址
./mihomoctl.sh refresh          # 用当前地址重新拉取节点
./mihomoctl.sh test             # 只测试订阅可否解析，不写入
./mihomoctl.sh test '<URL>'     # 测试新地址，不改订阅或节点
./mihomoctl.sh nodes            # 列出节点与延迟
./mihomoctl.sh use 手动选择 '<节点名>'
./mihomoctl.sh verify           # 硬验证：出口 IP 是否真的变了
./mihomoctl.sh log 50           # 日志尾部
./mihomoctl.sh env              # 输出终端代理环境变量（可 eval）

./proxyctl.sh on|off|status     # 系统代理（浏览器走不走代理看这个）
./proxyctl.sh refresh           # 换网络后重新应用到当前活跃网卡

sudo ./tun.sh on|off|status     # TUN 全局接管
```

## 可视化分流设置

菜单选择「分流设置…」，或再次打开 Amyfree.app，进入设置窗口。

1. **基础分流**：开关国内直连、常见广告拦截，选择其他流量走自动代理、手动代理或直连。
2. **添加规则**：粘贴网址或输入域名，选择「代理、直连、拦截」。默认包含该网站的子域名，也支持精确域名及 IPv4/IPv6 网段。
3. **调整顺序**：规则从上到下匹配，上移/下移改变优先级。自定义规则优先于基础分流，局域网保持直连。
4. **保存并应用**：内核校验通过后保存；运行时重载并读回验证，停止时供下次启动使用。检查或应用失败会保留草稿并还原配置。

「恢复推荐」只重置基础设置，保留自定义规则。「还原上次」载入上次保存前的规则，再点击保存即可还原。现有高级规则保留原格式，可调整顺序或删除；分流之外的订阅、节点和 DNS 配置保留。保存后使用规则模式，新连接按新规则连接。

分流与保存事务测试：`bash scripts/test-routing.sh`。当前 Command Line Tools 未提供 XCTest，测试使用无外部依赖的 Swift 断言运行器。

技术参考：[mihomo 规则优先级](https://wiki.metacubex.one/config/rules/)、[配置热重载 API](https://wiki.metacubex.one/api/)。

## 开机自启

菜单「开机自启（Amyfree）」控制 Amyfree 在登录 macOS 时自动启动。勾选与 macOS 实际登记状态同步；开启和关闭都会显示结果。如果需要系统允许，菜单显示「待系统允许」，并可直接打开系统登录项页面。

自启开关使用 [Apple SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice)，不依赖内核启动、订阅文件或独立 LaunchAgent。旧菜单栏自启记录在安装时迁移；代理内核的独立 LaunchAgent 仍由 `scripts/install-mihomo.sh` 管理。

回归测试：`bash scripts/test-startup.sh`。从已安装的应用核验状态：`~/Applications/Amyfree.app/Contents/MacOS/Amyfree --login-status`。

订阅兼容与回退测试：`python3 -m unittest discover -s tests -p 'test_subscription.py'`。测试涵盖 Clash YAML/JSON、链接/base64、类型保留、错误输入、不写入测试以及启动失败后的配置回退。

## 节点测速与链式代理

菜单「节点测速…」显示状态图标、延迟、下载速度和检测时间。每 **30 秒**自动检查全部节点的延迟与可用性，关闭测速窗口后仍继续。绿勾表示可用、黄钟表示较慢、红叉表示检测失败、灰问号表示未检测、蓝色图标表示检测中；同时显示文字。

「立即检测全部」手动检查延迟。「测选中节点下载速度」和「全部下载测速」下载每节点 **1 MB** 的真实测试样本，以 **MB/s** 显示短时平均速度（包括建连时间），不是延迟换算或最大带宽估计。检测使用隔离的代理会话，主代理关闭时仍可检查；不改变当前节点、链路或系统代理。进行下载测试时暂停重叠检测。

菜单「链式代理…」选择两个不同节点作为入口和出口，然后勾选启用并保存。流量顺序是 **设备 → 入口 → 出口 → 网站**，仅作用于自动/手动代理策略，直连及拦截规则保留。采用 [mihomo dialer-proxy](https://wiki.metacubex.one/config/proxies/dialer-proxy/)；为避免远端入口收到 fake-IP，链式开启时节点服务器地址使用加密 DNS，网站和局域网的 DNS 规则保留，关闭时恢复原节点解析设置。

开启后测速列表包含整条链路；更新订阅时同步链式节点凭据，入口或出口已删除时自动关闭链式并恢复策略组。保存前内核校验，运行时重载并读回验证，失败恢复配置。链式默认关闭，需选择节点后启用。

测试：`bash scripts/test-probe.sh` 和 `python3 -m unittest discover -s tests -p 'test_chain_speed.py'`。下载源使用 [Cloudflare 公开测速端点](https://github.com/cloudflare/speedtest)。

## 精简菜单与证书有效期

一级菜单仅显示运行状态、当前节点、代理开关、选择节点、节点测速、订阅、设置、工具和退出。节点列表、立即检测进入「选择节点」；订阅修改和更新进入「订阅」；分流、链式、系统代理、TUN、自启进入「设置」；出口验证、日志、终端、配置目录和关于进入「工具」。原快捷键保留。

测速窗口新增「证书有效期」，每 30 秒与节点检测并行更新。显示剩余天数，悬停可查看具体到期时间；30 天内到期为黄色，已过期/尚未生效为红色。信任或域名校验未通过单独标注，连接失败显示「无法确认」，REALITY、无 TLS 或暂不支持的 QUIC 节点不会误报过期。链式行显示入口、出口中最需关注的状态。

「响应延迟」使用 mihomo 的统一延迟口径：预热连接后计算测试站点的响应往返时间，避免把首次 DNS、TCP 和 TLS 握手开销显示为延迟；它不是 ICMP ping，也不是 MB/s 下载速度。测速会话仍然独立于主连接。内核无法复用第二次请求时可能回退到首请求耗时。依据：[mihomo 统一延迟](https://wiki.metacubex.one/config/general/)。

检查读取节点服务器叶证书，使用配置中的 SNI，不发送代理认证信息，也不修改节点的证书验证选项。诊断中读取不受信证书仅用于显示期限，结果仍保留校验失败状态。

证书测试：`python3 -m unittest discover -s tests -p 'test_cert_probe.py'`。菜单结构检查：`~/Applications/Amyfree.app/Contents/MacOS/Amyfree --menu-structure`。

---

## 平台与限制

| 项 | 说明 |
|---|---|
| 系统 | macOS 13+（开发环境 macOS 27 / Apple Silicon；Intel 需改 `build-app.sh` 里的 `-target`） |
| 内核 | mihomo v1.19.32，需 `with_gvisor` 构建才有 TUN |
| Python | 链接解析仅用标准库；Clash YAML 安全加载优先使用 PyYAML，macOS 可回退到系统 Ruby/Psych |
| TUN | **必须 root**；接管默认路由，非 root 无法创建 utun |
| 系统代理 | 只覆盖遵守系统代理的 App（浏览器、大部分 CLI）。不走系统代理的 App 请用 TUN |

### 已知行为

- **`curl` 不读 macOS 系统代理**。`proxyctl.sh on` 后用 `curl` 直连测试仍会失败，
  这是 curl 的行为，**不代表系统代理没生效**。验证方式见 `docs/GOTCHAS.md` 第 7 条。
- 系统代理开启后会写 `~/.config/mihomo/.proxy-state` 记录改过哪些网络服务，便于精准还原；
  该目录不可写时会退回临时目录。
- 退出菜单栏会撤销系统代理，但**不会**停止代理内核。

---

## 开发注意

1. **改配置前先读 `docs/GOTCHAS.md`**。DNS 那几条尤其容易改坏，且症状离原因很远。
2. 改 `main.swift` 后要**重新 `build-app.sh` 并 `install-menubar.sh`**，否则跑的还是旧二进制。
3. 验证二进制是否真的更新：往源码插一个 ASCII 标记再编译，然后 `grep -a 标记 二进制`
   （中文 UTF-8 字面量搜不到，别以此判断）。
4. `proxy-providers` 有本地缓存且**优先于订阅 URL**，换订阅后必须删 `providers/*.yaml` 再重启。
5. 本仓库**不含**任何二进制和凭据（内核/规则库用 `fetch-deps.sh` 拉，订阅地址与 API 密钥
   在安装时生成）。提交前请确认没有把 `.sub-url` / `.api-secret` / `config.yaml` 带进来。

## Release 构建

在 Apple Silicon 上运行 `bash scripts/build-release.sh`，需钥匙串中有 Developer ID Application 证书。脚本下载并校验固定版本的公开依赖，打包自带内核、规则库和 Python 的 DMG/ZIP，并生成 SHA-256 清单。

如已配置 Apple 公证凭据，使用 `NOTARY_PROFILE=钥匙串配置名 bash scripts/build-release.sh` 完成公证和票据装订。未提供 profile 时仅正式签名，不宣称已公证。签名身份也可通过 `CODE_SIGN_IDENTITY` 指定。

首次启动初始化与升级保留回归：`bash scripts/test-runtime.sh`。

## 在线更新与安装器

`scripts/install.sh` 只依赖 macOS 系统工具，支持从稳定 Release 下载，SHA-256、固定 Developer ID/team/bundle identity 校验，以及保留旧应用的替换事务。默认安装到已有位置，或 `/Applications` / `~/Applications`，不使用 sudo。应用内更新使用已签名包中的同一脚本，后台暂存后交给临时助手等待旧进程退出再替换并重开，不关闭正在使用的代理内核。失败日志在 `~/Library/Logs/Amyfree-update.log`。

更新模型测试：`bash scripts/test-update.sh`。安装器回归：`python3 scripts/test-installer.py`。签名包完整测试：`python3 scripts/test-release.py`。

终端安装可指定位置及关闭自动打开：`bash scripts/install.sh --target /绝对路径/Amyfree.app --no-open`。

## 在线更新规则库

菜单「工具 → 更新规则库…」与 `bash scripts/refresh-geodata.sh ~/.config/mihomo` 使用同一组件。先下载 GeoIP/GeoSite/MMDB 及 SHA-256，再用本机内核分别检查 DAT/MMDB；全部通过才替换，保存失败自动恢复。更新不触碰订阅或配置，不中断当前连接，下次启动代理生效。`GEODATA_BASE` 可覆盖规则库源，源须同时提供同名 `.sha256sum` 文件。

回归测试：`python3 -m unittest discover -s tests -p 'test_geodata_update.py'`。

## 统一升级中心（1.5.0）

菜单「升级中心」提供 Amyfree/GeoIP/GeoSite/MMDB 四个独立操作。应用安装助手通过实际 ZIP 字节数反馈进度；规则库组件输出 NDJSON 字节进度，可使用 `--check --json` 仅检查校验值，或 `--json --files geoip.dat` 单独更新。未选数据库参与格式验证但不替换。

检查时间与逐项红点提示保存在 UserDefaults；每隔 24 小时检测，重启和唤醒后仍按上次时间调度。查看窗口不会清除红点，完成对应升级才清除；检查失败保留已知提醒。

验证：`bash scripts/test-upgrade-center.sh`、`bash scripts/test-update.sh`、`python3 -m unittest discover -s tests -p 'test_geodata_update.py'`。界面离屏预览：`build/Amyfree.app/Contents/MacOS/Amyfree --render-upgrade-center build/upgrade-center.png`；追加 `--preview-progress` 可查看进度样式。
