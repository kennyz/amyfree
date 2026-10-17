// ============================================================
//  Rust 菜单栏（app-rs）与尚未迁移的 Swift 窗口之间的 C 接口。
//  全部在主线程调用；返回的字符串由 strdup 分配，调用方用 amy_free 释放。
//  每迁移一个窗口，就删掉这里对应的入口。
// ============================================================
import AppKit
import ServiceManagement

public typealias AmyCallback = @convention(c) () -> Void
public typealias AmyFlagCallback = @convention(c) (Bool) -> Void

private final class Bridge {
    static let shared = Bridge()
    lazy var probes = NodeProbeCoordinator(backend: LocalNodeProbeBackend(directory: CFG_DIR))
    lazy var upgrades = UpgradeCoordinator(directory: CFG_DIR)
    var probeWindow: NodeProbeWindowController?
    var upgradeWindow: UpgradeCenterWindowController?
    var routingWindow: RoutingWindowController?
    var chainWindow: ChainWindowController?
    var nodeManagerWindow: NodeManagerWindowController?
    var probesChanged: AmyCallback?
    var upgradesChanged: AmyCallback?
    var nodesSaved: AmyCallback?
    var routingSaving: AmyFlagCallback?
    var restartForUpdate: AmyCallback?
}

private func duplicate(_ text: String) -> UnsafeMutablePointer<CChar> { strdup(text)! }

private func json(_ object: Any) -> UnsafeMutablePointer<CChar> {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return duplicate(String(decoding: data, as: UTF8.self))
}

@_cdecl("amy_free")
public func amyFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }

@_cdecl("amy_ui_init")
public func amyUIInit(_ probesChanged: AmyCallback, _ upgradesChanged: AmyCallback, _ nodesSaved: AmyCallback,
                      _ routingSaving: AmyFlagCallback, _ restartForUpdate: AmyCallback) {
    let bridge = Bridge.shared
    bridge.probesChanged = probesChanged; bridge.upgradesChanged = upgradesChanged
    bridge.nodesSaved = nodesSaved; bridge.routingSaving = routingSaving; bridge.restartForUpdate = restartForUpdate
    bridge.probes.onChange = {
        bridge.probeWindow?.update()
        bridge.probesChanged?()
    }
    bridge.upgrades.onChange = {
        bridge.upgradeWindow?.update()
        bridge.upgradesChanged?()
    }
    bridge.upgrades.onApplicationReady = { directory in
        try AppUpdater.handoff(directory)
        bridge.probes.stop()
        bridge.restartForUpdate?()
        NSApp.terminate(nil)
    }
}

// MARK: 运行组件与登录项

/// 返回 1 表示已安装/更新，0 表示无需更新；出错时返回 -1 并写出错误文字。
@_cdecl("amy_runtime_prepare")
public func amyRuntimePrepare(_ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do { return try AppRuntime.prepare(directory: CFG_DIR) ? 1 : 0 }
    catch { message.pointee = duplicate(error.localizedDescription); return -1 }
}

@_cdecl("amy_login_state")
public func amyLoginState() -> UnsafeMutablePointer<CChar> { duplicate(LoginStartupController().state.rawValue) }

/// 成功时返回新状态，失败时返回 nil 并写出错误文字。
@_cdecl("amy_login_set")
public func amyLoginSet(_ enabled: Bool, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>? {
    do { return duplicate(try LoginStartupController().setEnabled(enabled).rawValue) }
    catch { message.pointee = duplicate(error.localizedDescription); return nil }
}

@_cdecl("amy_login_open_settings")
public func amyLoginOpenSettings() { SMAppService.openSystemSettingsLoginItems() }

// MARK: 图标

/// 返回 +1 引用的 NSImage（菜单栏模板图）。
@_cdecl("amy_cat_glyph")
public func amyCatGlyph(_ size: Double, _ awake: Bool) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(catGlyphImage(size: CGFloat(size), awake: awake)).toOpaque()
}

// MARK: 节点检测

@_cdecl("amy_probes_start")
public func amyProbesStart() { Bridge.shared.probes.start() }

@_cdecl("amy_probes_stop")
public func amyProbesStop() { Bridge.shared.probes.stop() }

@_cdecl("amy_probes_detect")
public func amyProbesDetect() { Bridge.shared.probes.detect() }

@_cdecl("amy_probes_state")
public func amyProbesState() -> UnsafeMutablePointer<CChar> {
    let probes = Bridge.shared.probes
    let rows: [[String: Any]] = probes.rows.map { row in
        var value: [String: Any] = ["name": row.name, "title": row.title, "indicator": row.visibleIndicator.rawValue,
                                    "indicator_title": row.visibleIndicator.title, "speed": row.speedText]
        if let delay = row.delay { value["delay"] = delay }
        return value
    }
    return json(["rows": rows, "checking": probes.checking, "downloading": probes.downloading,
                 "chain_enabled": probes.chain["enabled"] as? Bool == true,
                 "interval_minutes": NodeProbeCoordinator.intervalMinutes])
}

// MARK: 升级

@_cdecl("amy_upgrades_automatic_check")
public func amyUpgradesAutomaticCheck() { Bridge.shared.upgrades.automaticCheck() }

@_cdecl("amy_upgrades_state")
public func amyUpgradesState() -> UnsafeMutablePointer<CChar> {
    let upgrades = Bridge.shared.upgrades
    var value: [String: Any] = ["has_updates": upgrades.hasUpdates]
    if let version = upgrades.availableAppVersion { value["app_version"] = version }
    return json(value)
}

/// 仅渲染升级中心为 PNG 的诊断入口：不读用户设置、不安装、不联网。
@_cdecl("amy_render_upgrade_center")
public func amyRenderUpgradeCenter(_ path: UnsafePointer<CChar>, _ progress: Bool, _ application: Bool) -> Int32 {
    let preferences = UserDefaults(suiteName: "AmyfreeUpgradePreview.\(UUID().uuidString)")!
    let coordinator = UpgradeCoordinator(directory: CFG_DIR, defaults: preferences)
    coordinator.preview(progress: progress, application: application)
    let controller = UpgradeCenterWindowController(coordinator: coordinator)
    let content = controller.window!.contentView!
    content.layoutSubtreeIfNeeded()
    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return 1 }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let rendered = NSImage(size: content.bounds.size)
    rendered.lockFocus()
    NSColor.windowBackgroundColor.setFill(); content.bounds.fill()
    NSImage(cgImage: bitmap.cgImage!, size: content.bounds.size).draw(in: content.bounds)
    rendered.unlockFocus()
    guard let export = rendered.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
          let png = export.representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: String(cString: path)))) != nil else { return 1 }
    return 0
}

// MARK: 窗口

@_cdecl("amy_show_node_speed")
public func amyShowNodeSpeed(_ select: UnsafePointer<CChar>?) {
    let bridge = Bridge.shared
    if bridge.probeWindow == nil { bridge.probeWindow = NodeProbeWindowController(probes: bridge.probes) }
    bridge.probeWindow?.present()
    if let select = select { bridge.probeWindow?.selectNode(String(cString: select)) }
}

@_cdecl("amy_show_node_manager")
public func amyShowNodeManager(_ select: UnsafePointer<CChar>?) {
    let bridge = Bridge.shared
    if let current = bridge.nodeManagerWindow, current.window?.isVisible == true { current.present(); return }
    let controller = NodeManagerWindowController(selecting: select.map { String(cString: $0) })
    controller.onSaved = { bridge.probes.detect(); bridge.nodesSaved?() }
    bridge.nodeManagerWindow = controller; controller.present()
}

@_cdecl("amy_show_chain")
public func amyShowChain() {
    let bridge = Bridge.shared
    if let current = bridge.chainWindow, current.window?.isVisible == true { current.present(); return }
    let controller = ChainWindowController()
    controller.onSaved = { bridge.probes.detect(); bridge.nodesSaved?() }
    bridge.chainWindow = controller; controller.present()
}

/// 打不开时返回错误文字。
@_cdecl("amy_show_routing")
public func amyShowRouting() -> UnsafeMutablePointer<CChar>? {
    let bridge = Bridge.shared
    if let current = bridge.routingWindow, current.window?.isVisible == true { current.present(); return nil }
    do {
        let controller = try RoutingWindowController(store: makeRoutingStore())
        controller.onSaving = { saving in bridge.routingSaving?(saving) }
        bridge.routingWindow = controller; controller.present()
        return nil
    } catch { return duplicate(error.localizedDescription) }
}

@_cdecl("amy_show_upgrade_center")
public func amyShowUpgradeCenter() {
    let bridge = Bridge.shared
    if bridge.upgradeWindow == nil { bridge.upgradeWindow = UpgradeCenterWindowController(coordinator: bridge.upgrades) }
    bridge.upgradeWindow?.present()
    if bridge.upgrades.lastCheck == nil { bridge.upgrades.check() }
}

/// 切换语言后调用：测速和升级窗口会复用，关闭后下次按新语言重建；其余窗口每次打开都会新建。
@_cdecl("amy_reset_windows")
public func amyResetWindows() {
    let bridge = Bridge.shared
    bridge.probeWindow?.close(); bridge.probeWindow = nil
    bridge.upgradeWindow?.close(); bridge.upgradeWindow = nil
}
