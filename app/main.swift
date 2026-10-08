// ============================================================
//  Amyfree 菜单栏监控管理
//  纯 AppKit，无第三方依赖。编译: bash scripts/build-app.sh
// ============================================================
import Cocoa
import ServiceManagement

// MARK: - 路径

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
// 开发时可用 MIHOMO_HOME 指向仓库里的目录，避免去动 ~/.config：
//   MIHOMO_HOME=/path/to/repo/mihomo Amyfree.app/Contents/MacOS/Amyfree
let CFG_DIR = ProcessInfo.processInfo.environment["MIHOMO_HOME"] ?? "\(HOME)/.config/mihomo"
let CTL = "\(CFG_DIR)/mihomoctl.sh"
let PID_FILE = "\(CFG_DIR)/.mihomo.pid"
let SECRET_FILE = "\(CFG_DIR)/.api-secret"
let API = "127.0.0.1:9090"
let PROXY_URL = "http://127.0.0.1:7890"
let SUB_FILE = "\(CFG_DIR)/.sub-url"

// MARK: - 执行命令

struct RunResult {
    let status: Int32
    let out: String
}

@discardableResult
func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 25) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.currentDirectoryPath = CFG_DIR

    p.environment = AppRuntime.environment

    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = outPipe

    do {
        try p.run()
    } catch {
        return RunResult(status: -1, out: "无法执行: \(error.localizedDescription)")
    }

    // 超时保护：避免 curl 卡住导致菜单无响应
    let deadline = Date().addingTimeInterval(timeout)
    let sem = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global().async {
        data = outPipe.fileHandleForReading.readDataToEndOfFile()
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        if Date() > deadline {
            p.terminate()
            return RunResult(status: -2, out: "命令超时")
        }
    }
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return RunResult(status: p.terminationStatus, out: text)
}

// MARK: - 状态

var isRunning: Bool {
    guard let s = try? String(contentsOfFile: PID_FILE, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return kill(pid, 0) == 0
}

func apiSecret() -> String {
    (try? String(contentsOfFile: SECRET_FILE, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// 同步 HTTP GET（本地 API，极快；放后台线程调用）
func httpGet(_ urlStr: String, timeout: TimeInterval = 5) -> String? {
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    let secret = apiSecret()
    if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }

    var result: String?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let d = data { result = String(data: d, encoding: .utf8) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return result
}

/// 通过代理拿出口 IP（顺带证明代理确实通）
func fetchExitIP() -> String? {
    guard let url = URL(string: "http://ip-api.com/line/?fields=query,country") else { return nil }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: true,
        kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPPort as String: 7890,
        "HTTPSEnable": true,
        "HTTPSProxy": "127.0.0.1",
        "HTTPSPort": 7890,
    ]
    cfg.timeoutIntervalForRequest = 12
    let session = URLSession(configuration: cfg)

    var out: String?
    let sem = DispatchSemaphore(value: 0)
    session.dataTask(with: url) { data, _, _ in
        if let d = data { out = String(data: d, encoding: .utf8) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 16)
    return out?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " / ")
}

/// 取"手动选择"组当前节点名与延迟
func fetchCurrentNode() -> (name: String, delay: Int)? {
    guard let json = httpGet("http://\(API)/proxies/%E6%89%8B%E5%8A%A8%E9%80%89%E6%8B%A9"),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let now = obj["now"] as? String ?? "-"
    var delay = 0
    if let hist = obj["history"] as? [[String: Any]], let last = hist.last {
        delay = last["delay"] as? Int ?? 0
    }
    // 实测：Selector 组自身 history 常为空，此时改为查该节点自己的延迟
    if delay == 0, now != "-" {
        let enc = now.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? now
        if let njson = httpGet("http://\(API)/proxies/\(enc)"),
           let nd = njson.data(using: .utf8),
           let nobj = try? JSONSerialization.jsonObject(with: nd) as? [String: Any],
           let nh = nobj["history"] as? [[String: Any]], let nlast = nh.last {
            delay = nlast["delay"] as? Int ?? 0
        }
    }
    return (now, delay)
}

/// 取 TUN 是否开启
func tunEnabled() -> Bool {
    guard let s = try? String(contentsOfFile: "\(CFG_DIR)/config.yaml", encoding: .utf8) else { return false }
    return s.contains("\ntun:") || s.hasPrefix("tun:")
}

/// 系统代理是否已开启（浏览器等 App 走代理的前提）
/// 逐个服务回读 networksetup，不依赖服务名，也不相信自己的状态文件
func systemProxyAnyOn() -> Bool {
    let r = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
    let services = r.out.split(separator: "\n").dropFirst()
        .map { $0.hasPrefix("*") ? String($0.dropFirst()) : String($0) }
    for s in services {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if run("/usr/sbin/networksetup", ["-getwebproxy", t]).out.contains("Enabled: Yes") {
            return true
        }
    }
    return false
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let nodesMenu = NSMenu()
    var nodePickerItem: NSMenuItem!

    // 动态菜单项
    var headerItem: NSMenuItem!
    var runningItem: NSMenuItem!
    var exitIPItem: NSMenuItem!
    var nodeItem: NSMenuItem!
    var toggleItem: NSMenuItem!
    var sysProxyItem: NSMenuItem!
    var tunItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var nodeListLabel: NSMenuItem!
    var nodeSeparator: NSMenuItem!
    var nodeNames: [String] = []

    var busy = false
    var exitIPFailCount = 0
    var refreshTimer: Timer?
    var routingWindow: RoutingWindowController?
    var probeWindow: NodeProbeWindowController?
    var chainWindow: ChainWindowController?
    var cachedNodeProxies: [[String: Any]] = []
    var probeStatusItem: NSMenuItem!
    var probeNowItem: NSMenuItem!
    var chainItem: NSMenuItem!
    var upgradeItem: NSMenuItem!
    var upgradeWindow: UpgradeCenterWindowController?
    var upgradeBadge: NSView?
    var lastUpgradeBadge: Bool?
    var updatingForRestart = false
    var updateTimer: Timer?
    lazy var upgrades = UpgradeCoordinator(directory: CFG_DIR)
    lazy var probes = NodeProbeCoordinator(backend: LocalNodeProbeBackend(directory: CFG_DIR))
    let loginStartup = LoginStartupController()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不占 Dock

        do { try AppRuntime.prepare(directory: CFG_DIR) }
        catch {
            showResult(title: "无法准备运行组件", text: error.localizedDescription)
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shield.lefthalf.filled",
                                           accessibilityDescription: "Amyfree")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = " …"
        statusItem.menu = menu
        menu.delegate = self

        menu.autoenablesItems = false
        buildMenu()
        probes.onChange = { [weak self] in
            guard let self = self else { return }
            self.probeWindow?.update()
            self.rebuildNodeList()
            self.probeStatusItem.title = self.probes.checking ? "节点检测中…" : "节点自动检测：每 30 秒"
            self.probeNowItem.isEnabled = !self.probes.checking && !self.probes.downloading
            self.chainItem.state = self.probes.chain["enabled"] as? Bool == true ? .on : .off
        }
        probes.start()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.refresh() }
        if CommandLine.arguments.contains("--routing-settings") { showRoutingRules() }
        if CommandLine.arguments.contains("--node-speed") { showNodeSpeed() }
        if CommandLine.arguments.contains("--chain-settings") { showChainSettings() }
        if !FileManager.default.fileExists(atPath: SUB_FILE) { editSubscription() }
        upgrades.onChange = { [weak self] in self?.upgradeWindow?.update(); self?.updateUpgradeBadge() }
        upgrades.onApplicationReady = { [weak self] directory in
            guard let self = self else { throw AppUpdateError(message: "应用已退出，请重试。") }
            try AppUpdater.handoff(directory)
            self.updatingForRestart = true
            self.probes.stop(); self.refreshTimer?.invalidate(); self.updateTimer?.invalidate()
            NSApp.terminate(nil)
        }
        installUpgradeBadge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.upgrades.automaticCheck() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in self.upgrades.automaticCheck() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkUpgradesAfterWake), name: NSWorkspace.didWakeNotification, object: nil)
        if CommandLine.arguments.contains("--upgrade-center") { showUpgradeCenter() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRoutingRules()
        return true
    }

    // MARK: 菜单骨架

    func buildMenu() {
        func action(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let child = NSMenu(title: title); child.autoenablesItems = false; child.delegate = self
            items.forEach { child.addItem($0) }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = child
            return item
        }
        menu.removeAllItems()
        headerItem = NSMenuItem(title: "Amyfree", action: nil, keyEquivalent: "")
        runningItem = NSMenuItem(title: "Amyfree：检测中…", action: nil, keyEquivalent: "")
        runningItem.isEnabled = false; menu.addItem(runningItem)
        nodeItem = NSMenuItem(title: "当前节点：—", action: nil, keyEquivalent: "")
        nodeItem.isEnabled = false; menu.addItem(nodeItem)
        menu.addItem(.separator())
        toggleItem = action("启用代理", #selector(toggleProxy), "t"); menu.addItem(toggleItem)

        nodesMenu.autoenablesItems = false; nodesMenu.delegate = self
        nodePickerItem = NSMenuItem(title: "选择节点", action: nil, keyEquivalent: "")
        nodePickerItem.submenu = nodesMenu; menu.addItem(nodePickerItem)
        nodeListLabel = NSMenuItem(title: "订阅节点", action: nil, keyEquivalent: "")
        nodeListLabel.isEnabled = false
        nodeSeparator = .separator()
        probeNowItem = action("立即检测全部节点", #selector(detectNodes))
        probeStatusItem = NSMenuItem(title: "自动检测：每 30 秒", action: nil, keyEquivalent: "")
        probeStatusItem.isEnabled = false
        menu.addItem(action("节点测速…", #selector(showNodeSpeed), "d"))
        upgradeItem = action("升级中心…", #selector(showUpgradeCenter))
        menu.addItem(.separator())

        menu.addItem(submenu("订阅", [action("修改订阅地址…", #selector(editSubscription), "u"),
                                       action("更新订阅并重启", #selector(doRefreshSub), "r")]))
        sysProxyItem = action("系统代理", #selector(toggleSystemProxy), "s")
        tunItem = action("TUN 全局接管", #selector(toggleTun))
        loginItem = action("开机自启（Amyfree）", #selector(toggleLogin))
        chainItem = action("链式代理…", #selector(showChainSettings))
        menu.addItem(submenu("设置", [sysProxyItem, action("分流设置…", #selector(showRoutingRules), ","),
                                       chainItem, .separator(), tunItem, loginItem]))
        exitIPItem = NSMenuItem(title: "出口 IP：—", action: nil, keyEquivalent: "")
        exitIPItem.isEnabled = false
        menu.addItem(submenu("工具", [exitIPItem, action("验证出口 IP…", #selector(doVerify), "v"), .separator(),
                                       action("打开终端（已配代理）", #selector(openTerminal)),
                                       action("查看日志", #selector(openLog), "l"),
                                       action("打开配置目录", #selector(openConfigDir)), .separator(),
                                       upgradeItem,
                                       action("关于 Amyfree…", #selector(showAbout))]))
        menu.addItem(.separator())
        menu.addItem(action("退出 Amyfree", #selector(quitApp), "q"))
        rebuildNodeList()
    }

    // MARK: 刷新

    @objc func refresh() {
        loginItem.isEnabled = !busy
        guard !busy else { return }

        let running = isRunning
        toggleItem.title = running ? "关闭代理" : "启用代理"

        if running {
            statusItem.button?.title = " 开启"
            runningItem.title = "Amyfree：代理已开启"
        } else {
            statusItem.button?.title = " 关闭"
            runningItem.title = "Amyfree：代理已关闭"
            exitIPItem.title = "出口 IP: —"
            nodeItem.title = "当前节点: —"
        }

        tunItem.state = tunEnabled() ? .on : .off
        switch loginStartup.state {
        case .enabled: loginItem.state = .on; loginItem.title = "开机自启（Amyfree）"
        case .requiresApproval: loginItem.state = .mixed; loginItem.title = "开机自启（待系统允许）"
        case .disabled, .unavailable: loginItem.state = .off; loginItem.title = "开机自启（Amyfree）"
        }

        // 网络/系统查询放后台，避免卡菜单
        DispatchQueue.global(qos: .utility).async {
            var ip: String?
            var node: (name: String, delay: Int)?
            var proxyAny = false
            if isRunning {
                ip = fetchExitIP()
                node = fetchCurrentNode()
            }
            // 内核没跑时系统代理不该留着，否则浏览器指向死端口
            proxyAny = systemProxyAnyOn()
            var providerNodes: [[String: Any]] = []
            if isRunning, let json = httpGet("http://\(API)/providers/proxies/nodes"),
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                providerNodes = object["proxies"] as? [[String: Any]] ?? []
            }
            DispatchQueue.main.async {
                self.cachedNodeProxies = providerNodes
                if isRunning {
                    if let got = ip {
                        self.exitIPFailCount = 0
                        self.exitIPItem.title = "出口 IP: \(got)"
                    } else {
                        self.exitIPFailCount += 1
                        self.exitIPItem.title = self.exitIPFailCount >= 2
                            ? "出口 IP: 获取失败（节点可能已失效）"
                            : "出口 IP: 获取中…"
                    }
                    if let nd = node {
                        let measurement = self.probes.rows.first { $0.name == nd.name }
                        let title = measurement?.title ?? (nd.name == "MIMIO_CHAIN_EXIT" ? "链式代理" : nd.name)
                        let delay = measurement?.delay ?? nd.delay
                        self.nodeItem.title = delay > 0 ? "当前节点: \(title) (\(delay)ms)" : "当前节点: \(title)"
                    } else {
                        self.nodeItem.title = "当前节点: —"
                    }
                } else {
                    self.exitIPItem.title = "出口 IP: —（内核未运行）"
                    self.nodeItem.title = "当前节点: —"
                }

                if !isRunning && proxyAny {
                    self.sysProxyItem.title = "系统代理: 残留（内核已停）"
                    self.sysProxyItem.state = .on
                } else if proxyAny {
                    self.sysProxyItem.title = "系统代理: 已开启 ✓"
                    self.sysProxyItem.state = .on
                } else {
                    self.sysProxyItem.title = "系统代理: 未开启（浏览器不会走代理）"
                    self.sysProxyItem.state = .off
                }

                self.rebuildNodeList()
            }
        }
    }

    /// 节点列表：点击即切换（写入"手动选择"组）
    func rebuildNodeList() {
        nodesMenu.removeAllItems()
        nodesMenu.addItem(nodeListLabel)
        nodesMenu.addItem(.separator())
        nodeNames = []
        let measurements = probes.rows.filter { $0.name != "MIMIO_CHAIN_EXIT" }
        let names = measurements.isEmpty ? cachedNodeProxies.compactMap { $0["name"] as? String } : measurements.map(\.name)
        nodeListLabel.title = "订阅节点（\(names.count) 个）"
        nodePickerItem.title = "选择节点（\(names.count)）"
        for name in names {
            let result = measurements.first { $0.name == name }
            let suffix = result?.delay.map { "  ·  \($0) ms" } ?? ""
            let item = NSMenuItem(title: name + suffix, action: #selector(pickNode(_:)), keyEquivalent: "")
            item.image = probeIcon(result?.visibleIndicator ?? .unknown)
            item.toolTip = (result?.visibleIndicator.title ?? "未检测") + " · 下载：" + (result?.speedText ?? "未测速")
            item.target = self; item.representedObject = name
            item.isEnabled = true
            nodesMenu.addItem(item); nodeNames.append(name)
        }
        nodesMenu.addItem(nodeSeparator)
        nodesMenu.addItem(probeNowItem)
        nodesMenu.addItem(probeStatusItem)
    }

    // MARK: 动作

    @objc func showNodeSpeed() {
        if probeWindow == nil { probeWindow = NodeProbeWindowController(probes: probes) }
        probeWindow?.present()
    }
    @objc func detectNodes() { probes.detect() }
    @objc func showChainSettings() {
        if let current = chainWindow, current.window?.isVisible == true { current.present(); return }
        let controller = ChainWindowController()
        controller.onSaved = { [weak self] in self?.probes.detect(); self?.refresh() }
        chainWindow = controller; controller.present()
    }

    @objc func showRoutingRules() {
        if let current = routingWindow, current.window?.isVisible == true { current.present(); return }
        do {
            let controller = try RoutingWindowController(store: makeRoutingStore())
            controller.onSaving = { [weak self] saving in self?.busy = saving; if !saving { self?.refresh() } }
            routingWindow = controller
            controller.present()
        } catch { showResult(title: "无法打开分流设置", text: error.localizedDescription) }
    }

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let appInfo = "应用版本：\(version)（构建 \(build)）"

        // 直接查询已安装的内核，服务停止时也能查看版本；后台读取避免卡住菜单。
        DispatchQueue.global(qos: .utility).async {
            let binary = "\(CFG_DIR)/mihomo"
            let kernelVersion: String
            if !FileManager.default.isExecutableFile(atPath: binary) {
                kernelVersion = "未安装"
            } else {
                let result = run(binary, ["-v"], timeout: 5)
                let tokens = result.out.split(whereSeparator: { $0.isWhitespace })
                if result.status == 0,
                   let version = tokens.first(where: { $0.hasPrefix("v") && $0.dropFirst().first?.isNumber == true }) {
                    kernelVersion = "mihomo \(version)"
                } else {
                    kernelVersion = result.status == -2 ? "读取超时" : "无法读取"
                }
            }
            DispatchQueue.main.async {
                self.showResult(title: "关于 Amyfree", text: "\(appInfo)\n内核版本：\(kernelVersion)")
            }
        }
    }

    @objc func pickNode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if !isRunning { showNodeSpeed(); probeWindow?.selectNode(name); return }
        if probes.chain["enabled"] as? Bool == true { showChainSettings(); return }
        busy = true
        DispatchQueue.global().async {
            _ = run("/bin/bash", [CTL, "use", "手动选择", name])
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    @objc func toggleProxy() {
        busy = true
        let running = isRunning
        statusItem.button?.title = running ? " 停止中…" : " 启动中…"
        DispatchQueue.global().async {
            if running {
                // 关代理：先把系统代理撤掉，避免浏览器指向一个已停的端口
                _ = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", "off"])
                _ = run("/bin/bash", [CTL, "stop"])
            } else {
                let r = run("/bin/bash", [CTL, "start"])
                if r.status == 0 {
                    // 启动成功后接管系统代理，否则浏览器仍是直连
                    let p = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", "on"])
                    if p.status != 0 {
                        DispatchQueue.main.async {
                            self.showResult(title: "系统代理设置失败",
                                text: "代理内核已启动，但系统代理未能开启，浏览器仍会直连。\n\n"
                                    + "可尝试手动执行：\n  \(CFG_DIR)/proxyctl.sh on\n\n\(p.out)")
                        }
                    }
                }
            }
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    /// 只切换系统代理，不动内核
    @objc func toggleSystemProxy() {
        busy = true
        let on = systemProxyAnyOn()
        statusItem.button?.title = on ? " 撤销系统代理…" : " 设置系统代理…"
        DispatchQueue.global().async {
            let r = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", on ? "off" : "on"])
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if r.status != 0 { self.showResult(title: "系统代理操作结果", text: r.out) }
            }
        }
    }

    @objc func doVerify() {
        busy = true
        statusItem.button?.title = " 验证中…"
        DispatchQueue.global().async {
            let r = run("/bin/bash", ["\(CFG_DIR)/verify_node.sh", "7890", API, apiSecret(), "手动选择"])
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                self.showResult(title: "节点验证结果", text: r.out)
            }
        }
    }

    @objc func doRefreshSub() {
        busy = true
        statusItem.button?.title = " 更新订阅…"
        DispatchQueue.global().async {
            let r = run("/bin/bash", [CTL, "refresh"], timeout: 180)
            let msg = r.out
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                self.showResult(title: "更新订阅", text: msg)
            }
        }
    }

    // MARK: 修改订阅地址

    func currentSubURL() -> String {
        let s = (try? String(contentsOfFile: SUB_FILE, encoding: .utf8)) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc func editSubscription() {
        let current = currentSubURL()

        let alert = NSAlert()
        alert.messageText = "修改订阅地址"
        alert.informativeText = "支持 base64 编码的原始链接订阅，也支持 Clash/YAML 格式。"
            + "\n保存后会自动重新拉取节点并重启代理。"
        alert.addButton(withTitle: "保存并更新")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "仅测试")       // .alertSecondButtonReturn
        alert.addButton(withTitle: "取消")         // .alertThirdButtonReturn

        // 输入框
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 24))
        field.stringValue = current
        field.placeholderString = "https://example.com/subs/xxxxxxxx"
        field.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = field

        // 让输入框直接获得焦点，省一次点击
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        let resp = alert.runModal()
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard resp != .alertThirdButtonReturn else { return }   // 取消

        // 校验
        guard !input.isEmpty else {
            showResult(title: "订阅地址为空", text: "没有输入任何内容，未做修改。")
            return
        }
        guard input.hasPrefix("http://") || input.hasPrefix("https://") else {
            showResult(title: "格式不正确", text: "订阅地址必须以 http:// 或 https:// 开头。")
            return
        }

        let isTestOnly = (resp == .alertSecondButtonReturn)

        busy = true
        statusItem.button?.title = isTestOnly ? " 测试订阅…" : " 更新订阅…"

        DispatchQueue.global().async {
            let args = isTestOnly ? [CTL, "test", input] : [CTL, "sub", input]
            let result = run("/bin/bash", args, timeout: 180)
            let title = isTestOnly ? "订阅测试结果" : result.status == 0 ? "订阅更新成功" : "订阅更新失败"
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                self.showResult(title: title, text: result.out)
            }
        }
    }

    @objc func toggleTun() {
        let enabling = !tunEnabled()
        if enabling {
            let alert = NSAlert()
            alert.messageText = "开启 TUN 全局接管需要管理员权限"
            alert.informativeText = "开启后所有 App 的流量都会被接管。系统会弹出密码框。"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        busy = true
        DispatchQueue.global().async {
            // 用 osascript 提权执行 tun.sh
            let cmd = "do shell script \"/bin/bash '\(CFG_DIR)/tun.sh' \(enabling ? "on" : "off")\" with administrator privileges"
            let r = run("/usr/bin/osascript", ["-e", cmd], timeout: 60)
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if r.status != 0 { self.showResult(title: "TUN 操作结果", text: r.out) }
            }
        }
    }

    @objc func toggleLogin() {
        guard !busy else { return }
        if loginStartup.state == .requiresApproval { showLoginApproval(); return }
        let enabling = loginStartup.state != .enabled
        busy = true
        loginItem.isEnabled = false
        loginItem.title = "正在\(enabling ? "开启" : "关闭")自启…"
        DispatchQueue.global().async {
            let result = Result { try self.loginStartup.setEnabled(enabling) }
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                switch result {
                case .success(.requiresApproval): self.showLoginApproval()
                case .success:
                    self.showResult(title: enabling ? "已开启开机自启" : "已关闭开机自启",
                                    text: enabling ? "Amyfree 会在你登录 macOS 后自动启动。" : "Amyfree 不再随登录自动启动，当前应用继续运行。")
                case .failure(let error): self.showResult(title: "自启设置失败", text: error.localizedDescription)
                }
            }
        }
    }

    func showLoginApproval() {
        let alert = NSAlert()
        alert.messageText = "开机自启需要系统允许"
        alert.informativeText = "macOS 已登记 Amyfree，但尚未允许它随登录启动。请在「系统设置 → 通用 → 登录项」中允许 Amyfree。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "取消自启")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        else if response == .alertThirdButtonReturn {
            do { try loginStartup.setEnabled(false); refresh() }
            catch { showResult(title: "自启设置失败", text: error.localizedDescription) }
        }
    }

    @objc func openTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(CFG_DIR) && export https_proxy=\(PROXY_URL) http_proxy=\(PROXY_URL) all_proxy=socks5://127.0.0.1:7890 no_proxy='localhost,127.0.0.1,::1,*.local,192.168.0.0/16,10.0.0.0/8' && echo '已配置代理环境变量:' && env | grep -i proxy"
        end tell
        """
        run("/usr/bin/osascript", ["-e", script])
    }

    @objc func openLog() {
        _ = run("/usr/bin/open", ["-a", "Console", "\(CFG_DIR)/mihomo.log"])
        if !FileManager.default.fileExists(atPath: "\(CFG_DIR)/mihomo.log") {
            showResult(title: "日志", text: "日志文件尚未生成（服务可能还没启动过）。")
        }
    }

    @objc func openConfigDir() {
        _ = run("/usr/bin/open", [CFG_DIR])
    }

    @objc func quitApp() {
        probes.stop()
        // 退出前撤掉系统代理，避免浏览器被指向 127.0.0.1:7890 这个死端口。
        // 注意：不动代理内核——退出菜单栏不该顺手把后台代理也关了。
        if systemProxyAnyOn() {
            _ = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", "off"])
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        probes.stop()
        if updatingForRestart { return }
        // 兜底：正常退出路径都清理一次
        if systemProxyAnyOn() {
            _ = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", "off"])
        }
    }

    @objc func showUpgradeCenter() {
        if upgradeWindow == nil { upgradeWindow = UpgradeCenterWindowController(coordinator: upgrades) }
        upgradeWindow?.present()
        if upgrades.lastCheck == nil { upgrades.check() }
    }

    @objc func checkUpgradesAfterWake() { upgrades.automaticCheck() }

    func installUpgradeBadge() {
        guard let button = statusItem.button else { return }
        let badge = UpgradeBadgeView(frame: .zero)
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([badge.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 17),
                                     badge.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
                                     badge.widthAnchor.constraint(equalToConstant: 6), badge.heightAnchor.constraint(equalToConstant: 6)])
        upgradeBadge = badge
        updateUpgradeBadge()
    }

    func updateUpgradeBadge() {
        let available = upgrades.hasUpdates
        guard lastUpgradeBadge != available else { return }
        lastUpgradeBadge = available
        upgradeBadge?.isHidden = !available
        upgradeItem?.title = available ? "升级中心 · 有可用更新…" : "升级中心…"
        upgradeItem?.image = available ? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "有可用更新")?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) : nil
        upgradeItem?.image?.isTemplate = false
        statusItem?.button?.toolTip = available ? "Amyfree · 有可用更新，打开升级中心" : "Amyfree"
    }

    func showResult(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(text.suffix(2500))
        alert.addButton(withTitle: "好")
        // 让弹窗浮到最前
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }
}

// MARK: - 入口

// Render-only diagnostic: no user preferences, runtime installation or network requests.
if let index = CommandLine.arguments.firstIndex(of: "--render-upgrade-center"), CommandLine.arguments.indices.contains(index + 1) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let preferences = UserDefaults(suiteName: "AmyfreeUpgradePreview.\(UUID().uuidString)")!
    let coordinator = UpgradeCoordinator(directory: CFG_DIR, defaults: preferences)
    coordinator.preview(progress: CommandLine.arguments.contains("--preview-progress"), application: CommandLine.arguments.contains("--preview-application"))
    let controller = UpgradeCenterWindowController(coordinator: coordinator)
    let content = controller.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let rendered = NSImage(size: content.bounds.size)
    rendered.lockFocus()
    NSColor.windowBackgroundColor.setFill(); content.bounds.fill()
    NSImage(cgImage: bitmap.cgImage!, size: content.bounds.size).draw(in: content.bounds)
    rendered.unlockFocus()
    let export = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
    try! export.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

if CommandLine.arguments.contains("--prepare-runtime") {
    do {
        guard try AppRuntime.prepare(directory: CFG_DIR) || FileManager.default.isExecutableFile(atPath: CTL) else {
            throw RuntimeInstallError(message: "此构建未包含运行组件。")
        }
        print("运行组件已就绪")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

// 诊断命令使用与菜单完全相同的系统接口，便于核验登记状态。
if let option = CommandLine.arguments.dropFirst().first,
   ["--login-status", "--enable-login", "--disable-login"].contains(option) {
    let startup = LoginStartupController()
    do {
        if option != "--login-status" { try startup.setEnabled(option == "--enable-login") }
        print(startup.state.rawValue)
        exit(startup.state == .requiresApproval ? 2 : 0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--menu-structure") {
    _ = NSApplication.shared
    let inspector = AppDelegate()
    inspector.buildMenu()
    func structure(_ menu: NSMenu) -> [[String: Any]] {
        menu.items.filter { !$0.isSeparatorItem }.map { item in
            var value: [String: Any] = ["title": item.title]
            if let child = item.submenu { value["items"] = structure(child) }
            return value
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: structure(inspector.menu), options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
