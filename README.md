# Amyfree

轻量、简洁的 macOS 菜单栏代理工具，基于 mihomo 内核。

## 核心优势

- **开箱即用**：内置运行组件，导入订阅、选择节点、一键连接。
- **原生轻量**：Swift / AppKit 界面，常驻菜单栏，不占 Dock。
- **订阅兼容**：支持 Clash YAML/JSON 和常见链接订阅。
- **连接可见**：自动检测节点延迟，支持实际下载测速和证书到期提醒。
- **按需设置**：国内直连、广告拦截、自定义分流，可选链式代理与 TUN。
- **升级中心**：应用与三个规则库分别升级，显示真实下载进度，每天检查并以红点提醒。

## 下载与使用

适用于 **macOS 13 及以上、Apple Silicon（M 系列芯片）**。

1. 在 [Releases](https://github.com/kennyz/amyfree/releases/latest) 下载 `Amyfree-版本号-macOS-arm64.dmg`。
2. 打开安装包，将 **Amyfree** 拖入 **Applications**，再打开应用。
3. 首次打开时填入自己的合法订阅地址，保存并更新。
4. 点击菜单栏盾牌图标，选择节点，开启代理。

应用使用 Apple Developer ID 签名；具体签名及公证状态见发布说明。若 macOS 提示阻止打开，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。TUN 模式需要管理员授权。

### curl 一键安装

在终端执行，无需安装开发工具：

```bash
curl -fsSL https://raw.githubusercontent.com/kennyz/amyfree/main/scripts/install.sh | bash
```

自动下载最新版、校验文件和签名，然后安装并打开。优先更新已有的安装位置；新安装放入 Applications，目录不可写时使用 `~/Applications`。

### 在线升级

点击菜单栏盾牌 → **升级中心…**。Amyfree、GeoIP、GeoSite 和 MMDB 分别提供升级按钮和下载进度；每 24 小时自动检查，发现更新显示红点，重启应用后仍保留提醒。应用升级后自动重开，规则库更新后重新启用代理生效；失败保留原版本和配置。`1.4.x` 用户可先通过旧菜单「工具 → 检查更新」升级，`1.3.4` 及更早版本使用上方命令或 DMG 更新一次。

本软件不提供订阅或节点服务。开发与源码构建说明见 [开发文档](docs/DEVELOPMENT.md)。

源码安装（需 Xcode Command Line Tools）：克隆仓库后执行 `bash scripts/build-app.sh && bash scripts/install-menubar.sh`，安装脚本会自动下载并安装内核和规则库。仅编译 App 不会安装运行依赖。

## 使用声明

**本软件仅用于合法合规的科学上网、学习、科研和工作。禁止用于政治活动及任何违法违规目的。使用者应遵守所在地法律法规，并对自身使用行为负责。**

第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
