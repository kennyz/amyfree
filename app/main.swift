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
func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 25, input: String? = nil) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.currentDirectoryPath = CFG_DIR

    p.environment = AppRuntime.environment

    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = outPipe
    // 节点配置含凭据，经标准输入传递，不出现在进程参数里
    let inPipe = input.map { _ in Pipe() }
    if let inPipe = inPipe { p.standardInput = inPipe }

    do {
        try p.run()
    } catch {
        return RunResult(status: -1, out: tr("无法执行: ", "Could not run: ") + error.localizedDescription)
    }
    if let inPipe = inPipe, let input = input {
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
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
            return RunResult(status: -2, out: tr("命令超时", "Command timed out"))
        }
    }
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return RunResult(status: p.terminationStatus, out: text)
}

// MARK: - 状态

var isRunning: Bool {
    guard let s = try? String(contentsOfFile: PID_FILE, encoding: .utf8) else {
        // 旧版以 root 启动的内核会留下仅 root 可读的 pid 文件，改问本地 API
        guard FileManager.default.fileExists(atPath: PID_FILE) else { return false }
        return httpGet("http://\(API)/version", timeout: 1) != nil
    }
    guard let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    // TUN 模式下内核以 root 运行，kill 返回 EPERM 也说明进程存在
    return kill(pid, 0) == 0 || errno == EPERM
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

/// 同步发送 PUT/DELETE 等请求到本地 API，返回是否成功（放后台线程调用）
@discardableResult
func httpSend(_ method: String, _ urlStr: String, json: [String: Any]? = nil, timeout: TimeInterval = 5) -> Bool {
    guard let url = URL(string: urlStr) else { return false }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = timeout
    let secret = apiSecret()
    if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
    if let json = json {
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, response, _ in
        ok = ((response as? HTTPURLResponse)?.statusCode).map { (200..<300).contains($0) } ?? false
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return ok
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

/// 取实际承载代理流量的 PROXY 组：当前节点、延迟，以及是否被手工固定。
/// PROXY 是自动测速组，分流规则都指向它；菜单选节点时把它固定到所选节点，"自动选择"则解除固定。
func fetchCurrentNode() -> (name: String, delay: Int, fixed: String?)? {
    guard let json = httpGet("http://\(API)/proxies/PROXY"),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let now = obj["now"] as? String ?? "-"
    // 固定的节点不可用时内核会临时改用最快节点，此时 now 与 fixed 不同
    let fixed = (obj["fixed"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
    return (now, delay, fixed)
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
    var glyphAwake: Bool?
    var nodeText: String?   // 合并到状态行的当前节点，如「LocJP3 (146ms)」
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
    var nodeManagerWindow: NodeManagerWindowController?
    var cachedNodeProxies: [[String: Any]] = []
    var currentNodeName: String?   // 被固定的节点；自动选择时为 nil
    var autoNodeName: String?      // 自动选择时内核当前选中的最快节点
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
            showResult(title: tr("无法准备运行组件", "Could not prepare runtime components"), text: error.localizedDescription)
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusGlyph(awake: false)
        statusItem.button?.title = " …"
        statusItem.menu = menu
        menu.delegate = self

        menu.autoenablesItems = false
        buildMenu()
        probes.onChange = { [weak self] in
            guard let self = self else { return }
            self.probeWindow?.update()
            self.rebuildNodeList()
            self.probeStatusItem.title = self.probeStatusTitle()
            self.probeNowItem.isEnabled = !self.probes.checking && !self.probes.downloading
            self.chainItem.state = self.probes.chain["enabled"] as? Bool == true ? .on : .off
        }
        probes.start()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.refresh() }
        if CommandLine.arguments.contains("--routing-settings") { showRoutingRules() }
        if CommandLine.arguments.contains("--node-speed") { showNodeSpeed() }
        if CommandLine.arguments.contains("--chain-settings") { showChainSettings() }
        if let index = CommandLine.arguments.firstIndex(of: "--node-manager") {
            // 可选参数：要选中的节点名（启动时当前节点尚未读取）
            let name = CommandLine.arguments.indices.contains(index + 1) && !CommandLine.arguments[index + 1].hasPrefix("-") ? CommandLine.arguments[index + 1] : nil
            openNodeManager(selecting: name)
        }
        if !FileManager.default.fileExists(atPath: SUB_FILE) { editSubscription() }
        upgrades.onChange = { [weak self] in self?.upgradeWindow?.update(); self?.updateUpgradeBadge() }
        upgrades.onApplicationReady = { [weak self] directory in
            guard let self = self else { throw AppUpdateError(message: tr("应用已退出，请重试。", "The app has quit. Please try again.")) }
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
        runningItem = NSMenuItem(title: tr("Amyfree：检测中…", "Amyfree: checking…"), action: nil, keyEquivalent: "")
        runningItem.isEnabled = false; menu.addItem(runningItem)
        menu.addItem(.separator())
        toggleItem = action(tr("启用代理", "Enable Proxy"), #selector(toggleProxy), "t"); menu.addItem(toggleItem)

        nodesMenu.autoenablesItems = false; nodesMenu.delegate = self
        nodePickerItem = NSMenuItem(title: tr("选择节点", "Select Node"), action: nil, keyEquivalent: "")
        nodePickerItem.submenu = nodesMenu; menu.addItem(nodePickerItem)
        nodeListLabel = NSMenuItem(title: tr("订阅节点", "Subscription Nodes"), action: nil, keyEquivalent: "")
        nodeListLabel.isEnabled = false
        nodeSeparator = .separator()
        probeNowItem = action(tr("立即检测全部节点", "Test All Nodes Now"), #selector(detectNodes))
        probeStatusItem = NSMenuItem(title: probeStatusTitle(), action: nil, keyEquivalent: "")
        probeStatusItem.isEnabled = false
        upgradeItem = action(tr("升级中心…", "Upgrade Center…"), #selector(showUpgradeCenter))
        menu.addItem(.separator())

        menu.addItem(submenu(tr("节点与订阅", "Nodes & Subscription"), [action(tr("节点管理…", "Node Management…"), #selector(showNodeManager), "e"), .separator(),
                                       action(tr("修改订阅地址…", "Edit Subscription URL…"), #selector(editSubscription), "u"),
                                       action(tr("更新订阅并重启", "Update Subscription & Restart"), #selector(doRefreshSub), "r")]))
        sysProxyItem = action(tr("系统代理", "System Proxy"), #selector(toggleSystemProxy), "s")
        tunItem = action(tr("TUN 全局接管", "TUN Mode (All Traffic)"), #selector(toggleTun))
        loginItem = action(tr("开机自启（Amyfree）", "Launch at Login (Amyfree)"), #selector(toggleLogin))
        chainItem = action(tr("链式代理…", "Chain Proxy…"), #selector(showChainSettings))
        let languageItems = AppLanguage.allCases.map { language -> NSMenuItem in
            let item = action(language.title, #selector(changeLanguage(_:)))
            item.representedObject = language.rawValue
            item.state = language == AppLanguage.current ? .on : .off
            return item
        }
        menu.addItem(submenu(tr("设置", "Settings"), [sysProxyItem, action(tr("分流设置…", "Routing Rules…"), #selector(showRoutingRules), ","),
                                       chainItem, .separator(), tunItem, loginItem, .separator(),
                                       submenu("Languages", languageItems)]))
        exitIPItem = NSMenuItem(title: tr("出口 IP：—", "Exit IP: —"), action: nil, keyEquivalent: "")
        exitIPItem.isEnabled = false
        menu.addItem(submenu(tr("工具", "Tools"), [action(tr("节点测速…", "Node Speed Test…"), #selector(showNodeSpeed), "d"), .separator(),
                                       exitIPItem, action(tr("验证出口 IP…", "Verify Exit IP…"), #selector(doVerify), "v"), .separator(),
                                       action(tr("打开终端（已配代理）", "Open Terminal (Proxy Set)"), #selector(openTerminal)),
                                       action(tr("查看日志", "View Log"), #selector(openLog), "l"),
                                       action(tr("打开配置目录", "Open Config Folder"), #selector(openConfigDir)), .separator(),
                                       upgradeItem]))
        menu.addItem(.separator())
        menu.addItem(action(tr("关于 Amyfree…", "About Amyfree…"), #selector(showAbout)))
        menu.addItem(action(tr("退出 Amyfree", "Quit Amyfree"), #selector(quitApp), "q"))
        rebuildNodeList()
    }

    // MARK: 刷新

    @objc func refresh() {
        loginItem.isEnabled = !busy
        guard !busy else { return }

        let running = isRunning
        toggleItem.title = running ? tr("关闭代理", "Disable Proxy") : tr("启用代理", "Enable Proxy")

        setStatusGlyph(awake: running)
        if running {
            statusItem.button?.title = tr(" 开启", " On")
            updateStatusLine()
        } else {
            statusItem.button?.title = tr(" 关闭", " Off")
            nodeText = nil; updateStatusLine()
            exitIPItem.title = tr("出口 IP: —", "Exit IP: —")
        }

        tunItem.state = tunEnabled() ? .on : .off
        switch loginStartup.state {
        case .enabled: loginItem.state = .on; loginItem.title = tr("开机自启（Amyfree）", "Launch at Login (Amyfree)")
        case .requiresApproval: loginItem.state = .mixed; loginItem.title = tr("开机自启（待系统允许）", "Launch at Login (needs approval)")
        case .disabled, .unavailable: loginItem.state = .off; loginItem.title = tr("开机自启（Amyfree）", "Launch at Login (Amyfree)")
        }

        // 网络/系统查询放后台，避免卡菜单
        DispatchQueue.global(qos: .utility).async {
            var ip: String?
            var node: (name: String, delay: Int, fixed: String?)?
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
                self.currentNodeName = isRunning ? node?.fixed : nil
                self.autoNodeName = isRunning && node != nil && node?.fixed == nil ? node?.name : nil
                if isRunning {
                    if let got = ip {
                        self.exitIPFailCount = 0
                        self.exitIPItem.title = tr("出口 IP: ", "Exit IP: ") + got
                    } else {
                        self.exitIPFailCount += 1
                        self.exitIPItem.title = self.exitIPFailCount >= 2
                            ? tr("出口 IP: 获取失败（节点可能已失效）", "Exit IP: unavailable (node may be down)")
                            : tr("出口 IP: 获取中…", "Exit IP: fetching…")
                    }
                    if let nd = node {
                        let measurement = self.probes.rows.first { $0.name == nd.name }
                        let title = measurement?.title ?? (nd.name == "MIMIO_CHAIN_EXIT" ? tr("链式代理", "Chain proxy") : nd.name)
                        let delay = measurement?.delay ?? nd.delay
                        let note: String
                        if nd.name == "MIMIO_CHAIN_EXIT" { note = "" }
                        else if let fixed = nd.fixed { note = fixed == nd.name ? "" : tr("（所选节点不可用，临时使用）", " (selected node unavailable, using this)") }
                        else { note = tr("（自动）", " (auto)") }
                        self.nodeText = delay > 0 ? "\(title + note) (\(delay)ms)" : title + note
                    } else {
                        self.nodeText = nil
                    }
                } else {
                    self.exitIPItem.title = tr("出口 IP: —（内核未运行）", "Exit IP: — (core not running)")
                    self.nodeText = nil
                }
                self.updateStatusLine()

                if !isRunning && proxyAny {
                    self.sysProxyItem.title = tr("系统代理: 残留（内核已停）", "System proxy: left on (core stopped)")
                    self.sysProxyItem.state = .on
                } else if proxyAny {
                    self.sysProxyItem.title = tr("系统代理: 已开启 ✓", "System proxy: on ✓")
                    self.sysProxyItem.state = .on
                } else {
                    self.sysProxyItem.title = tr("系统代理: 未开启（浏览器不会走代理）", "System proxy: off (browsers bypass proxy)")
                    self.sysProxyItem.state = .off
                }

                self.rebuildNodeList()
            }
        }
    }

    /// 自绘猫咪标志（与应用图标同源）：代理开启时睁眼，关闭时闭眼睡觉。模板图随菜单栏深浅色自动着色。
    func setStatusGlyph(awake: Bool) {
        guard glyphAwake != awake else { return }
        glyphAwake = awake
        let glyph = catGlyphImage(size: 18, awake: awake)
        glyph.isTemplate = true
        glyph.accessibilityDescription = awake ? tr("Amyfree：代理已开启", "Amyfree: proxy on") : tr("Amyfree：代理已关闭", "Amyfree: proxy off")
        statusItem.button?.image = glyph
    }

    /// 运行状态与当前节点合并为一行：「Amyfree：代理已开启 · 节点 (146ms)」
    func updateStatusLine() {
        guard isRunning else { runningItem.title = tr("Amyfree：代理已关闭", "Amyfree: proxy off"); return }
        runningItem.title = tr("Amyfree：代理已开启", "Amyfree: proxy on") + (nodeText.map { " · " + $0 } ?? "")
    }

    /// 节点列表：点击即切换（写入"手动选择"组）
    func rebuildNodeList() {
        nodesMenu.removeAllItems()
        nodesMenu.addItem(nodeListLabel)
        nodesMenu.addItem(.separator())
        nodeNames = []
        let measurements = probes.rows.filter { $0.name != "MIMIO_CHAIN_EXIT" }
        let names = measurements.isEmpty ? cachedNodeProxies.compactMap { $0["name"] as? String } : measurements.map(\.name)
        nodeListLabel.title = tr("订阅节点（\(names.count) 个）", "Subscription nodes (\(names.count))")
        nodePickerItem.title = tr("选择节点（\(names.count)）", "Select Node (\(names.count))")
        let chained = autoNodeName == "MIMIO_CHAIN_EXIT" || currentNodeName == "MIMIO_CHAIN_EXIT"
        let autoItem = NSMenuItem(title: tr("自动选择（最快）", "Auto (fastest)") + (autoNodeName.map { chained ? "" : " → \($0)" } ?? ""),
                                  action: #selector(pickAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = autoNodeName != nil && !chained ? .on : .off
        nodesMenu.addItem(autoItem)
        for name in names {
            let result = measurements.first { $0.name == name }
            let suffix = result?.delay.map { "  ·  \($0) ms" } ?? ""
            let item = NSMenuItem(title: name + suffix, action: #selector(pickNode(_:)), keyEquivalent: "")
            item.image = probeIcon(result?.visibleIndicator ?? .unknown)
            item.toolTip = (result?.visibleIndicator.title ?? tr("未检测", "Not tested")) + tr(" · 下载：", " · Download: ") + (result?.speedText ?? tr("未测速", "Not measured"))
            item.target = self; item.representedObject = name
            item.state = name == currentNodeName ? .on : .off
            item.isEnabled = true
            nodesMenu.addItem(item); nodeNames.append(name)
        }
        nodesMenu.addItem(nodeSeparator)
        nodesMenu.addItem(probeNowItem)
        nodesMenu.addItem(probeStatusItem)
    }

    func probeStatusTitle() -> String {
        if probes.checking { return tr("节点检测中…", "Testing nodes…") }
        let minutes = Int(NodeProbeCoordinator.interval / 60)
        return tr("节点自动检测：每 \(minutes) 分钟", "Auto test: every \(minutes) min")
    }

    // MARK: 动作

    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw),
              language != AppLanguage.current else { return }
        AppLanguage.current = language
        // 测速和升级窗口会复用，关闭后下次按新语言重建；分流、链式窗口每次打开都会新建。
        probeWindow?.close(); probeWindow = nil
        upgradeWindow?.close(); upgradeWindow = nil
        buildMenu()
        lastUpgradeBadge = nil; updateUpgradeBadge()
        glyphAwake = nil   // 按新语言重建图标的辅助说明
        probes.onChange?()
        refresh()
    }

    @objc func showNodeSpeed() {
        if probeWindow == nil { probeWindow = NodeProbeWindowController(probes: probes) }
        probeWindow?.present()
    }
    @objc func detectNodes() { probes.detect() }
    @objc func showNodeManager() { openNodeManager(selecting: nil) }
    func openNodeManager(selecting name: String?) {
        if let current = nodeManagerWindow, current.window?.isVisible == true { current.present(); return }
        // 默认编辑当前节点：手工固定的节点优先，其次是自动选择当前使用的节点
        let current = name ?? [currentNodeName, autoNodeName].compactMap { $0 }.first { $0 != "MIMIO_CHAIN_EXIT" }
        let controller = NodeManagerWindowController(selecting: current)
        controller.onSaved = { [weak self] in self?.probes.detect(); self?.refresh() }
        nodeManagerWindow = controller; controller.present()
    }
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
        } catch { showResult(title: tr("无法打开分流设置", "Could not open routing rules"), text: error.localizedDescription) }
    }

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? tr("未知", "unknown")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? tr("未知", "unknown")
        let appInfo = tr("应用版本：\(version)（构建 \(build)）", "App version: \(version) (build \(build))")

        // 直接查询已安装的内核，服务停止时也能查看版本；后台读取避免卡住菜单。
        DispatchQueue.global(qos: .utility).async {
            let binary = "\(CFG_DIR)/mihomo"
            let kernelVersion: String
            if !FileManager.default.isExecutableFile(atPath: binary) {
                kernelVersion = tr("未安装", "not installed")
            } else {
                let result = run(binary, ["-v"], timeout: 5)
                let tokens = result.out.split(whereSeparator: { $0.isWhitespace })
                if result.status == 0,
                   let version = tokens.first(where: { $0.hasPrefix("v") && $0.dropFirst().first?.isNumber == true }) {
                    kernelVersion = "mihomo \(version)"
                } else {
                    kernelVersion = result.status == -2 ? tr("读取超时", "timed out") : tr("无法读取", "unreadable")
                }
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = tr("关于 Amyfree", "About Amyfree")
                var text = appInfo + tr("\n内核版本：", "\nCore version: ") + kernelVersion
                if let latest = self.upgrades.availableAppVersion {
                    text += latest.isEmpty ? tr("\n\n🆕 发现新版本，可在升级中心升级。", "\n\n🆕 A new version is available in the Upgrade Center.")
                                           : tr("\n\n🆕 发现新版本 \(latest)，可在升级中心升级。", "\n\n🆕 Version \(latest) is available in the Upgrade Center.")
                } else if self.upgrades.hasUpdates {
                    text += tr("\n\n🆕 规则库有可用更新。", "\n\n🆕 Rule data updates are available.")
                }
                alert.informativeText = text
                alert.addButton(withTitle: tr("好", "OK"))
                alert.addButton(withTitle: self.upgrades.hasUpdates ? tr("立即升级…", "Upgrade Now…") : tr("升级中心…", "Upgrade Center…"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn { self.showUpgradeCenter() }
            }
        }
    }

    @objc func pickNode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if !isRunning { showNodeSpeed(); probeWindow?.selectNode(name); return }
        if probes.chain["enabled"] as? Bool == true { showChainSettings(); return }
        busy = true
        DispatchQueue.global().async {
            // 分流规则走 PROXY（自动测速组），固定它才能让所选节点真正承载流量；手动选择组同步，供"代理 · 手动选择"规则使用
            _ = run("/bin/bash", [CTL, "use", "PROXY", name])
            _ = run("/bin/bash", [CTL, "use", "手动选择", name])
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    /// 解除 PROXY 组的固定，恢复按延迟自动选择最快节点
    @objc func pickAuto() {
        guard isRunning else { return }
        if probes.chain["enabled"] as? Bool == true { showChainSettings(); return }
        busy = true
        DispatchQueue.global().async {
            httpSend("DELETE", "http://\(API)/proxies/PROXY")
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    @objc func toggleProxy() {
        busy = true
        let running = isRunning
        statusItem.button?.title = running ? tr(" 停止中…", " Stopping…") : tr(" 启动中…", " Starting…")
        DispatchQueue.global().async {
            if running {
                // 关代理：先把系统代理撤掉，避免浏览器指向一个已停的端口
                _ = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", "off"])
                var r = run("/bin/bash", [CTL, "stop"])
                // TUN 模式下内核以 root 运行，普通用户无权停止，改为管理员授权停止
                if r.status != 0 { r = self.runTunScript("stop") }
                if r.status != 0 {
                    DispatchQueue.main.async { self.showResult(title: tr("无法关闭代理", "Could not disable the proxy"), text: r.out) }
                }
            } else {
                // TUN 需要 root 才能建立虚拟网卡，开启时经管理员授权启动
                let r = tunEnabled() ? self.runTunScript("start") : run("/bin/bash", [CTL, "start"])
                if r.status == 0 {
                    // 启动成功后接管系统代理，否则浏览器仍是直连
                    let p = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", "on"])
                    if p.status != 0 {
                        DispatchQueue.main.async {
                            self.showResult(title: tr("系统代理设置失败", "Could not set system proxy"),
                                text: tr("代理内核已启动，但系统代理未能开启，浏览器仍会直连。\n\n可尝试手动执行：",
                                         "The proxy core started, but the system proxy could not be enabled, so browsers still connect directly.\n\nTry running manually:")
                                    + "\n  \(CFG_DIR)/proxyctl.sh on\n\n\(p.out)")
                        }
                    }
                } else {
                    DispatchQueue.main.async { self.showResult(title: tr("无法启用代理", "Could not enable the proxy"), text: r.out) }
                }
            }
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    /// 以管理员权限运行 tun.sh（系统弹出密码框）。提权后的 shell 不继承本进程环境，语言需显式传入。
    func runTunScript(_ action: String) -> RunResult {
        let cmd = "do shell script \"AMYFREE_LANG=\(AppLanguage.current.rawValue) /bin/bash '\(CFG_DIR)/tun.sh' \(action)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", cmd], timeout: 60)
    }

    /// 只切换系统代理，不动内核
    @objc func toggleSystemProxy() {
        busy = true
        let on = systemProxyAnyOn()
        statusItem.button?.title = on ? tr(" 撤销系统代理…", " Clearing system proxy…") : tr(" 设置系统代理…", " Setting system proxy…")
        DispatchQueue.global().async {
            let r = run("/bin/bash", ["\(CFG_DIR)/proxyctl.sh", on ? "off" : "on"])
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if r.status != 0 { self.showResult(title: tr("系统代理操作结果", "System Proxy"), text: r.out) }
            }
        }
    }

    @objc func doVerify() {
        busy = true
        statusItem.button?.title = tr(" 验证中…", " Verifying…")
        DispatchQueue.global().async {
            let r = run("/bin/bash", ["\(CFG_DIR)/verify_node.sh", "7890", API, apiSecret(), "手动选择"])
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                self.showResult(title: tr("节点验证结果", "Node Verification"), text: r.out)
            }
        }
    }

    @objc func doRefreshSub() {
        busy = true
        statusItem.button?.title = tr(" 更新订阅…", " Updating…")
        DispatchQueue.global().async {
            let r = run("/bin/bash", [CTL, "refresh"], timeout: 180)
            let msg = r.out
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                self.showResult(title: tr("更新订阅", "Update Subscription"), text: msg)
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
        alert.messageText = tr("修改订阅地址", "Edit Subscription URL")
        alert.informativeText = tr("支持 base64 编码的原始链接订阅，也支持 Clash/YAML 格式。\n保存后会自动重新拉取节点并重启代理。",
                                   "Supports base64-encoded link subscriptions and Clash YAML.\nSaving re-fetches the nodes and restarts the proxy.")
        alert.addButton(withTitle: tr("保存并更新", "Save & Update"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: tr("仅测试", "Test Only"))          // .alertSecondButtonReturn
        alert.addButton(withTitle: tr("取消", "Cancel"))               // .alertThirdButtonReturn

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
            showResult(title: tr("订阅地址为空", "Empty subscription URL"), text: tr("没有输入任何内容，未做修改。", "Nothing was entered; no changes made."))
            return
        }
        guard input.hasPrefix("http://") || input.hasPrefix("https://") else {
            showResult(title: tr("格式不正确", "Invalid format"), text: tr("订阅地址必须以 http:// 或 https:// 开头。", "The subscription URL must start with http:// or https://."))
            return
        }

        let isTestOnly = (resp == .alertSecondButtonReturn)

        busy = true
        statusItem.button?.title = isTestOnly ? tr(" 测试订阅…", " Testing…") : tr(" 更新订阅…", " Updating…")

        DispatchQueue.global().async {
            let args = isTestOnly ? [CTL, "test", input] : [CTL, "sub", input]
            let result = run("/bin/bash", args, timeout: 180)
            let title = isTestOnly ? tr("订阅测试结果", "Subscription Test") : result.status == 0 ? tr("订阅更新成功", "Subscription Updated") : tr("订阅更新失败", "Subscription Update Failed")
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
            alert.messageText = tr("开启 TUN 全局接管需要管理员权限", "TUN mode needs administrator rights")
            alert.informativeText = tr("开启后所有 App 的流量都会被接管。系统会弹出密码框。", "All app traffic will go through the proxy. macOS will ask for your password.")
            alert.addButton(withTitle: tr("继续", "Continue"))
            alert.addButton(withTitle: tr("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        busy = true
        DispatchQueue.global().async {
            let r = self.runTunScript(enabling ? "on" : "off")
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if r.status != 0 { self.showResult(title: tr("TUN 操作结果", "TUN Mode"), text: r.out) }
            }
        }
    }

    @objc func toggleLogin() {
        guard !busy else { return }
        if loginStartup.state == .requiresApproval { showLoginApproval(); return }
        let enabling = loginStartup.state != .enabled
        busy = true
        loginItem.isEnabled = false
        loginItem.title = enabling ? tr("正在开启自启…", "Enabling launch at login…") : tr("正在关闭自启…", "Disabling launch at login…")
        DispatchQueue.global().async {
            let result = Result { try self.loginStartup.setEnabled(enabling) }
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                switch result {
                case .success(.requiresApproval): self.showLoginApproval()
                case .success:
                    self.showResult(title: enabling ? tr("已开启开机自启", "Launch at login enabled") : tr("已关闭开机自启", "Launch at login disabled"),
                                    text: enabling ? tr("Amyfree 会在你登录 macOS 后自动启动。", "Amyfree will start automatically when you log in to macOS.")
                                                   : tr("Amyfree 不再随登录自动启动，当前应用继续运行。", "Amyfree will no longer start at login; the running app keeps running."))
                case .failure(let error): self.showResult(title: tr("自启设置失败", "Launch at login failed"), text: error.localizedDescription)
                }
            }
        }
    }

    func showLoginApproval() {
        let alert = NSAlert()
        alert.messageText = tr("开机自启需要系统允许", "Launch at login needs approval")
        alert.informativeText = tr("macOS 已登记 Amyfree，但尚未允许它随登录启动。请在「系统设置 → 通用 → 登录项」中允许 Amyfree。",
                                   "macOS registered Amyfree but hasn't allowed it to start at login. Allow Amyfree in System Settings → General → Login Items.")
        alert.addButton(withTitle: tr("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: tr("稍后", "Later"))
        alert.addButton(withTitle: tr("取消自启", "Turn Off"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        else if response == .alertThirdButtonReturn {
            do { try loginStartup.setEnabled(false); refresh() }
            catch { showResult(title: tr("自启设置失败", "Launch at login failed"), text: error.localizedDescription) }
        }
    }

    @objc func openTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(CFG_DIR) && export https_proxy=\(PROXY_URL) http_proxy=\(PROXY_URL) all_proxy=socks5://127.0.0.1:7890 no_proxy='localhost,127.0.0.1,::1,*.local,192.168.0.0/16,10.0.0.0/8' && echo '\(tr("已配置代理环境变量:", "Proxy environment variables set:"))' && env | grep -i proxy"
        end tell
        """
        run("/usr/bin/osascript", ["-e", script])
    }

    @objc func openLog() {
        _ = run("/usr/bin/open", ["-a", "Console", "\(CFG_DIR)/mihomo.log"])
        if !FileManager.default.fileExists(atPath: "\(CFG_DIR)/mihomo.log") {
            showResult(title: tr("日志", "Log"), text: tr("日志文件尚未生成（服务可能还没启动过）。", "No log file yet (the core may never have started)."))
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
        upgradeItem?.title = available ? tr("升级中心 · 有可用更新…", "Upgrade Center · Update Available…") : tr("升级中心…", "Upgrade Center…")
        upgradeItem?.image = available ? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: tr("有可用更新", "Update available"))?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) : nil
        upgradeItem?.image?.isTemplate = false
        statusItem?.button?.toolTip = available ? tr("Amyfree · 有可用更新，打开升级中心", "Amyfree · Update available — open the Upgrade Center") : "Amyfree"
    }

    func showResult(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(text.suffix(2500))
        alert.addButton(withTitle: tr("好", "OK"))
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
            throw RuntimeInstallError(message: tr("此构建未包含运行组件。", "This build does not include runtime components."))
        }
        print(tr("运行组件已就绪", "Runtime components ready"))
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
