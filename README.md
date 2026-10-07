# Amyfree

轻量、简洁的 macOS 菜单栏代理工具，基于 mihomo 内核。

## 核心优势

- **开箱即用**：内置运行组件，导入订阅、选择节点、一键连接。
- **原生轻量**：Swift / AppKit 界面，常驻菜单栏，不占 Dock。
- **订阅兼容**：支持 Clash YAML/JSON 和常见链接订阅。
- **连接可见**：自动检测节点延迟，支持实际下载测速和证书到期提醒。
- **按需设置**：国内直连、广告拦截、自定义分流，可选链式代理与 TUN。

## 下载与使用

适用于 **macOS 13 及以上、Apple Silicon（M 系列芯片）**。

1. 在 [Releases](https://github.com/kennyz/amyfree/releases/latest) 下载 `Amyfree-版本号-macOS-arm64.dmg`。
2. 打开安装包，将 **Amyfree** 拖入 **Applications**，再打开应用。
3. 首次打开时填入自己的合法订阅地址，保存并更新。
4. 点击菜单栏盾牌图标，选择节点，开启代理。

应用使用 Apple Developer ID 签名；具体签名及公证状态见发布说明。若 macOS 提示阻止打开，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。TUN 模式需要管理员授权。

本软件不提供订阅或节点服务。开发与源码构建说明见 [开发文档](docs/DEVELOPMENT.md)。

## 使用声明

**本软件仅用于合法合规的科学上网、学习、科研和工作。禁止用于政治活动及任何违法违规目的。使用者应遵守所在地法律法规，并对自身使用行为负责。**

第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
