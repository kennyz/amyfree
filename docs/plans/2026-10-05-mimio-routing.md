# Mimio Routing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将应用改名为 Mimio，提供无需编辑 YAML 的原生分流设置。

**Architecture:** Foundation 模型读取现有 rules，保留高级规则和其余配置；AppKit 窗口提供基础开关、规则列表、添加编辑与排序。保存使用内核校验，事务写入并在运行时通过 API 重载，失败回退。

**Tech Stack:** Swift / Foundation / AppKit / mihomo REST API，无第三方依赖。

---

## 1. 规则模型与保存事务

- 新建 `app/RoutingModel.swift`：只解析项目采用的 YAML rules 列表，识别基础规则、域名和 IP 网段；高级规则原样保留。
- 输入支持网址提取域名、包含子域名/精确匹配、IPv4/IPv6 CIDR；禁止控制字符和分隔符注入。
- 保存只修改 rules 与 mode，校验后更新 config.yaml、.run-config.yaml 和存在时的无 TUN 备份；配置变动冲突、校验失败或应用失败均不留下部分修改。
- `tests/main.swift` 使用原生 Swift 断言运行器验证优先级、保留配置、校验失败、冲突和回退（本机 CLT 不含 XCTest）；使用真实内核验证生成配置与热重载。

## 2. 原生可视化窗口

- 新建 `app/RoutingRules.swift`，添加 `main.swift` 菜单入口及再次打开应用时的窗口入口。
- 单窗口：基础设置、按优先级排列的规则列表、添加/编辑/删除/上下移动、推荐设置、还原上次、保存并应用。
- 新建规则用原生表单，常用三种连接方式：代理、直连、拦截；高级规则显示为只读条目。
- 显示未保存、保存中、失败及成功状态，关闭未保存窗口时提示，所有按钮支持键盘访问。

## 3. 名称与交付

- 修改 Info.plist、构建/安装脚本、README，迁移 MihomoMini 和早期名称，保留配置目录与 Bundle Identifier。
- 版本 1.2.0，构建 4；沿用 M 盾牌图标。
- 编译、静态检查、签名验证；安装并启动 Mimio，在原生界面检查表单、保存和重开读取。

工作区无 Git 元数据，因此在当前目录实施，不创建提交或工作树。

参考：[规则格式与优先级](https://wiki.metacubex.one/config/rules/)、[配置重载 API](https://wiki.metacubex.one/api/)。
