# MihomoMini 应用图标

沿用现有菜单栏盾牌元素，用深蓝圆角底板、蓝绿色盾牌和白色 M 形节点连线绘制应用图标。

图标用原生 AppKit 代码绘制，源码为 `scripts/generate-icon.swift`；构建脚本生成 16–1024 像素的十个 PNG 表示，再使用 `iconutil` 打包为 `Contents/Resources/AppIcon.icns`。Info.plist 通过 CFBundleIconFile 指向该资源。菜单栏保持适合系统明暗模式的单色图标。

版本为 1.1.1，构建号为 3。验证涵盖大小尺寸预览、透明通道、ICNS 格式、构建、静态检查和严格代码签名。
