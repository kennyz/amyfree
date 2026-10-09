import AppKit

final class UpgradeCoordinator {
    let directory: String
    private let defaults: UserDefaults
    private let applicationCheck: () throws -> AvailableUpdate?
    private let geodataCheck: (() throws -> [String: Any])?
    private(set) var rows = Dictionary(uniqueKeysWithValues: UpgradeComponent.allCases.map { ($0, UpgradeRowState()) })
    private(set) var checking = false
    private(set) var active: UpgradeComponent?
    private(set) var release: AvailableUpdate?
    var onChange: (() -> Void)?
    var onApplicationReady: ((URL) throws -> Void)?
    var lastCheck: Date? { defaults.object(forKey: "AmyfreeUpgrade.lastCheck") as? Date }
    var hasUpdates: Bool { rows.values.contains { $0.available } }
    var lastAttempt: Date? { defaults.object(forKey: "AmyfreeUpgrade.lastAttempt") as? Date }

    init(directory: String, defaults: UserDefaults = .standard,
         applicationCheck: @escaping () throws -> AvailableUpdate? = AppUpdater.check,
         geodataCheck: (() throws -> [String: Any])? = nil) {
        self.directory = directory; self.defaults = defaults
        self.applicationCheck = applicationCheck; self.geodataCheck = geodataCheck
        for component in UpgradeComponent.allCases {
            rows[component]?.available = defaults.bool(forKey: "AmyfreeUpgrade.available.\(component.rawValue)")
            if rows[component]?.available == true { rows[component]?.message = "发现可用更新" }
            else if lastCheck != nil { rows[component]?.message = "上次检查已是最新版本" }
        }
        if let tag = defaults.string(forKey: "AmyfreeUpgrade.availableTag"),
           let remote = AppVersion(tag), let current = AppVersion(AppUpdater.currentVersion), remote <= current {
            setAvailable(false, for: .application)
            rows[.application]?.message = "当前版本已更新"
        }
    }
    private func changed() { onChange?() }
    func preview(progress: Bool, application: Bool = false, knownTotal: Bool = true) {
        rows[.application] = UpgradeRowState(available: true, working: progress && application, message: "有新版本可升级", progress: progress && application ? UpgradeProgress(received: 20_000_000, total: 57_000_000, phase: "正在下载…") : nil)
        rows[.geoip] = UpgradeRowState(available: progress && !application, working: progress && !application, message: "已是最新版本", progress: progress && !application ? UpgradeProgress(received: 5_800_000, total: 16_500_000, phase: "正在下载…") : nil)
        rows[.geosite] = UpgradeRowState(available: true, message: "发现新版规则库")
        rows[.mmdb] = UpgradeRowState(message: "已是最新版本")
        active = progress ? (application ? .application : .geoip) : nil
        if !knownTotal, let active = active { rows[active]?.progress?.total = 0 }
    }
    private func setAvailable(_ value: Bool, for component: UpgradeComponent) {
        rows[component]?.available = value
        defaults.set(value, forKey: "AmyfreeUpgrade.available.\(component.rawValue)")
    }
    func automaticCheck() {
        guard UpgradeSchedule.isDue(lastCheck: lastAttempt) else { return }
        check()
    }
    func check() {
        guard !checking && active == nil else { return }
        checking = true
        defaults.set(Date(), forKey: "AmyfreeUpgrade.lastAttempt")
        for component in UpgradeComponent.allCases { rows[component]?.checking = true; rows[component]?.message = "正在检查…" }
        changed()
        DispatchQueue.global(qos: .utility).async {
            let appResult = Result { try self.applicationCheck() }
            let geoResult = Result { try self.geodataCheck?() ?? self.checkGeodata() }
            DispatchQueue.main.async {
                self.checking = false
                for component in UpgradeComponent.allCases { self.rows[component]?.checking = false }
                switch appResult {
                case .success(let update):
                    self.release = update
                    self.setAvailable(update != nil, for: .application)
                    self.defaults.set(update?.tag, forKey: "AmyfreeUpgrade.availableTag")
                    self.rows[.application]?.message = update.map { "新版本 \($0.version) 可升级" } ?? "已是最新版本"
                case .failure(let error): self.rows[.application]?.message = error.localizedDescription
                }
                switch geoResult {
                case .success(let files):
                    for component in UpgradeComponent.allCases where component.file != nil {
                        guard let item = files[component.file!] as? [String: Any], let available = item["available"] as? Bool else {
                            self.rows[component]?.message = "无法读取检查结果，请重试。"; continue
                        }
                        self.setAvailable(available, for: component)
                        self.rows[component]?.message = available ? "发现新版规则库" : "已是最新版本"
                    }
                case .failure(let error):
                    for component in UpgradeComponent.allCases where component.file != nil { self.rows[component]?.message = error.localizedDescription }
                }
                if case .success = appResult, case .success = geoResult { self.defaults.set(Date(), forKey: "AmyfreeUpgrade.lastCheck") }
                self.changed()
            }
        }
    }
    private func checkGeodata() throws -> [String: Any] {
        let helper = "\(directory)/geodata_update.py"
        guard FileManager.default.fileExists(atPath: helper) else { throw AppUpdateError(message: "运行组件尚未准备好，请重新安装应用。") }
        let result = try UpgradeProcess.run(AppRuntime.python, [helper, "--home", directory, "--check", "--json"], timeout: 700)
        let objects = Self.events(result.text)
        guard result.status == 0, let files = objects.last(where: { $0["event"] as? String == "checked" })?["files"] as? [String: Any] else {
            let detail = objects.last?["message"] as? String ?? "规则库检查失败，请检查网络后重试。"
            throw AppUpdateError(message: detail)
        }
        return files
    }
    static func events(_ text: String) -> [[String: Any]] {
        text.components(separatedBy: "\n").compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
    func start(_ component: UpgradeComponent) {
        guard active == nil && !checking else { return }
        if component == .application && release == nil { check(); return }
        active = component; rows[component]?.working = true
        rows[component]?.progress = UpgradeProgress(); rows[component]?.message = "准备下载…"; changed()
        DispatchQueue.global(qos: .utility).async {
            do {
                if component == .application {
                    guard let release = self.release else { throw AppUpdateError(message: "请先检查新版。") }
                    let staged = try AppUpdater.stage(release) { progress in self.report(progress, for: component) }
                    DispatchQueue.main.async {
                        do {
                            guard let install = self.onApplicationReady else { throw AppUpdateError(message: "无法启动安装助手，请重试。") }
                            try install(staged)
                        } catch {
                            try? FileManager.default.removeItem(at: staged)
                            self.finish(component, error: error)
                        }
                    }
                } else {
                    let helper = "\(self.directory)/geodata_update.py"
                    var consumed = 0
                    let result = try UpgradeProcess.run(AppRuntime.python, [helper, "--home", self.directory, "--json", "--files", component.file!], timeout: 1000, output: { output in
                        let events = Self.events(output.components(separatedBy: "\n").dropLast().joined(separator: "\n"))
                        for event in events.dropFirst(consumed) where event["event"] as? String == "progress" {
                            let phase = event["phase"] as? String ?? ""
                            let caption = phase == "validating" ? "正在校验规则格式…" : phase == "installing" ? "正在保存…" : "正在下载…"
                            self.report(UpgradeProgress(received: (event["downloaded"] as? NSNumber)?.int64Value ?? 0,
                                                        total: (event["total"] as? NSNumber)?.int64Value ?? 0, phase: caption), for: component)
                        }
                        consumed = events.count
                    })
                    let events = Self.events(result.text)
                    guard result.status == 0 else { throw AppUpdateError(message: events.last?["message"] as? String ?? "更新失败，旧规则库已保留。") }
                    DispatchQueue.main.async {
                        self.setAvailable(false, for: component)
                        self.finish(component, message: "已更新 · 重新启用代理后生效")
                    }
                }
            } catch { DispatchQueue.main.async { self.finish(component, error: error) } }
        }
    }
    private func report(_ progress: UpgradeProgress, for component: UpgradeComponent) {
        DispatchQueue.main.async {
            guard self.active == component else { return }
            let displayed = progress.retainingDownload(from: self.rows[component]?.progress)
            self.rows[component]?.progress = displayed; self.rows[component]?.message = progress.phase; self.changed()
        }
    }
    private func finish(_ component: UpgradeComponent, message: String = "", error: Error? = nil) {
        active = nil; rows[component]?.working = false; rows[component]?.progress = nil
        rows[component]?.message = error?.localizedDescription ?? message
        changed()
    }
}

final class UpgradeDownloadBar: NSView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        let amount = min(1, max(0, fraction))
        guard amount > 0 else { return }
        NSColor.controlAccentColor.setFill()
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * amount, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

private final class UpgradeRowView: NSView {
    let component: UpgradeComponent
    let dot = NSTextField(labelWithString: "●")
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let state = NSTextField(wrappingLabelWithString: "尚未检查")
    let bar = UpgradeDownloadBar()
    private var progressDisplay = UpgradeProgressDisplay.hidden
    let button = NSButton(title: "检查更新", target: nil, action: nil)
    init(_ component: UpgradeComponent) {
        self.component = component
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 12
        layer?.borderWidth = 1; layer?.borderColor = NSColor.separatorColor.cgColor
        title.stringValue = component.title; title.font = .systemFont(ofSize: 15, weight: .semibold)
        detail.stringValue = component.detail; detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 12); state.maximumNumberOfLines = 2; state.textColor = .secondaryLabelColor
        dot.textColor = .systemRed; dot.font = .systemFont(ofSize: 9); dot.isHidden = true
        dot.setAccessibilityLabel("有可用更新")
        bar.isHidden = true
        button.bezelStyle = .rounded
        for view in [dot, title, detail, state, bar, button] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 106),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            dot.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6), dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), button.centerYAnchor.constraint(equalTo: topAnchor, constant: 31), button.widthAnchor.constraint(equalToConstant: 118),
            state.leadingAnchor.constraint(equalTo: title.leadingAnchor), state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18), state.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 9),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18), bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), bar.heightAnchor.constraint(equalToConstant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -18),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateProgress(_ display: UpgradeProgressDisplay) {
        guard display != progressDisplay else { return }
        switch display {
        case .hidden:
            bar.isHidden = true
        case .determinate(let fraction):
            bar.isHidden = false; bar.fraction = fraction
        }
        progressDisplay = display
    }
}

final class UpgradeCenterWindowController: NSWindowController {
    let coordinator: UpgradeCoordinator
    private let last = NSTextField(labelWithString: "")
    private let check = NSButton(title: "检查更新", target: nil, action: nil)
    private var rowViews: [UpgradeComponent: UpgradeRowView] = [:]
    init(coordinator: UpgradeCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Amyfree · 升级中心"; window.isReleasedWhenClosed = false
        super.init(window: window)
        build(); update(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { update(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    private func build() {
        let title = NSTextField(labelWithString: "升级中心"); title.font = .systemFont(ofSize: 26, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "应用与规则库分别升级，订阅和设置始终保留。")
        subtitle.textColor = .secondaryLabelColor; subtitle.font = .systemFont(ofSize: 13)
        last.font = .systemFont(ofSize: 11); last.textColor = .secondaryLabelColor
        check.bezelStyle = .rounded; check.target = self; check.action = #selector(checkNow)
        let controls = NSStackView(views: [last, NSView(), check]); controls.orientation = .horizontal; controls.alignment = .centerY
        var contents: [NSView] = [title, subtitle, controls]
        for component in UpgradeComponent.allCases {
            let row = UpgradeRowView(component); rowViews[component] = row
            row.button.target = self; row.button.action = #selector(upgrade(_:)); row.button.tag = UpgradeComponent.allCases.firstIndex(of: component)!
            contents.append(row)
        }
        let note = NSTextField(labelWithString: "每 24 小时自动检查 · 红点表示有可用更新")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; contents.append(note)
        let root = NSStackView(views: contents); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        let content = window!.contentView!; content.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        for view in contents { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)])
    }
    func update() {
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        last.stringValue = coordinator.lastCheck.map { "上次检查：\(formatter.string(from: $0))" } ?? "尚未完成检查"
        check.isEnabled = !coordinator.checking && coordinator.active == nil
        check.title = coordinator.checking ? "正在检查…" : "检查更新"
        for component in UpgradeComponent.allCases {
            let row = rowViews[component]!, state = coordinator.rows[component]!
            row.dot.isHidden = !state.available
            let local: String
            if let file = component.file {
                let attributes = try? FileManager.default.attributesOfItem(atPath: "\(coordinator.directory)/\(file)")
                local = (attributes?[.modificationDate] as? Date).map { "本地更新：\(formatter.string(from: $0))" } ?? "尚未安装"
            } else { local = "当前版本 \(AppUpdater.currentVersion)" }
            row.detail.stringValue = local
            row.state.stringValue = state.progress?.text ?? state.message
            row.updateProgress(UpgradeProgressDisplay(state: state, isActive: coordinator.active == component))
            row.button.title = state.working ? "正在升级…" : component == .application ? (state.available ? "升级并重启" : "检查更新") : (state.available ? "升级规则库" : "重新下载")
            row.button.isEnabled = coordinator.active == nil && !coordinator.checking
            row.button.setAccessibilityLabel("\(component.title) · \(row.button.title)")
        }
    }
    @objc private func checkNow() { coordinator.check() }
    @objc private func upgrade(_ sender: NSButton) {
        let component = UpgradeComponent.allCases[sender.tag]
        if component == .application, let release = coordinator.release {
            let alert = NSAlert(); alert.messageText = "升级至 Amyfree \(release.version)？"
            alert.informativeText = "下载并校验后会重新打开应用，订阅和设置将保留。"
            alert.addButton(withTitle: "升级并重启"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        coordinator.start(component)
    }
}

final class UpgradeBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
