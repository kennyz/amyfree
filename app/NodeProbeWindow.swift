import AppKit

func probeLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.maximumNumberOfLines = 2
    return field
}
func probeStack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY; stack.spacing = spacing
    return stack
}
func probeIcon(_ indicator: NodeIndicator) -> NSImage? {
    let symbol: String; let color: NSColor
    switch indicator {
    case .good: symbol = "checkmark.circle.fill"; color = .systemGreen
    case .slow: symbol = "clock.fill"; color = .systemYellow
    case .failed: symbol = "xmark.circle.fill"; color = .systemRed
    case .testing: symbol = "arrow.triangle.2.circlepath.circle.fill"; color = .systemBlue
    case .unknown, .paused: symbol = "questionmark.circle.fill"; color = .secondaryLabelColor
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: indicator.title)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
    image?.isTemplate = false
    return image
}

final class NodeProbeWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {
    let probes: NodeProbeCoordinator
    private let table = NSTableView()
    private let status = probeLabel("", size: 12, color: .secondaryLabelColor)
    private let summary = probeLabel("", size: 13, weight: .medium)
    private let check = NSButton(title: "立即检测全部", target: nil, action: nil)
    private let download = NSButton(title: "测选中节点下载速度", target: nil, action: nil)
    private let allDownload = NSButton(title: "全部下载测速", target: nil, action: nil)
    private var selectedName: String?

    init(probes: NodeProbeCoordinator) {
        self.probes = probes
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 535),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Amyfree · 节点测速"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 950, height: 550)
        super.init(window: window)
        build(); update(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func selectNode(_ name: String) {
        selectedName = name
        if let index = probes.rows.firstIndex(where: { $0.name == name }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
    private func build() {
        let title = probeLabel("节点测速", size: 25, weight: .semibold)
        let caption = probeLabel("每 30 秒检测延迟、可用性和证书有效期；下载速度可手工测试。", color: .secondaryLabelColor)
        table.dataSource = self; table.delegate = self; table.rowHeight = 46
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        for (id, title, width) in [("state", "状态", 105.0), ("node", "订阅节点 / 链路", 275.0),
                                   ("delay", "响应延迟", 80.0), ("speed", "下载速度", 120.0),
                                   ("certificate", "证书有效期", 180.0), ("time", "最近检测", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = width - 10
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 245).isActive = true
        check.target = self; check.action = #selector(detect)
        download.target = self; download.action = #selector(downloadSelected)
        allDownload.target = self; allDownload.action = #selector(downloadAll)
        for button in [check, download, allDownload] { button.bezelStyle = .rounded }
        let buttons = probeStack([check, download, allDownload], vertical: false, spacing: 10)
        let legend = probeLabel("● 可用   ◷ 较慢   ✕ 检测失败   ? 未检测   ↻ 检测中", size: 12, color: .secondaryLabelColor)
        let note = probeLabel("下载测速每节点使用 1 MB 样本，显示短时平均速度；测速不会改变当前节点或链路。", size: 12, color: .secondaryLabelColor)
        let root = probeStack([title, caption, summary, scroll, legend, status, buttons, note], spacing: 12)
        let content = window!.contentView!; content.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                     root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                                     root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
    }
    func update() {
        let selected = selectedName.flatMap { name in probes.rows.firstIndex { $0.name == name } }
        table.reloadData()
        if let selected = selected { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        let available = probes.rows.filter { [.good, .slow].contains($0.indicator) }.count
        let failures = probes.rows.filter { $0.indicator == .failed }.count
        summary.stringValue = "\(probes.rows.count) 个节点 / 链路  ·  \(available) 个可用  ·  \(failures) 个检测失败"
        status.stringValue = probes.message
        let idle = !probes.checking && !probes.downloading
        check.isEnabled = idle
        download.isEnabled = idle && probes.rows.indices.contains(table.selectedRow)
        allDownload.isEnabled = idle && !probes.rows.isEmpty
    }
    func numberOfRows(in tableView: NSTableView) -> Int { probes.rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedName = probes.rows.indices.contains(table.selectedRow) ? probes.rows[table.selectedRow].name : nil
        download.isEnabled = !probes.checking && !probes.downloading && probes.rows.indices.contains(table.selectedRow)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let child = content(for: tableColumn, row: row) else { return nil }
        let host = NSView(); host.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 5),
                                     child.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -5),
                                     child.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
        return host
    }
    private func content(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = probes.rows[row]
        switch tableColumn?.identifier.rawValue {
        case "state":
            let icon = NSImageView(); icon.image = probeIcon(item.visibleIndicator)
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            return probeStack([icon, probeLabel(item.visibleIndicator.title, size: 12)], vertical: false, spacing: 6)
        case "node":
            let label = probeLabel(item.title, weight: .medium); label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle; label.toolTip = item.title; return label
        case "delay":
            let label = probeLabel(item.delayText, size: 12)
            label.toolTip = "经节点预热连接后的测试站点响应延迟，不是下载速度或 ICMP ping。"
            return label
        case "speed":
            let label = probeLabel(item.speedText, size: 12)
            if let date = item.downloadedAt { label.toolTip = "下载测速时间：\(Self.format(date))" }
            return label
        case "certificate":
            let icon = NSImageView(); icon.image = probeIcon(item.certificate.indicator)
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            let text = probeLabel(item.certificate.text, size: 12); text.maximumNumberOfLines = 1
            let cell = probeStack([icon, text], vertical: false, spacing: 5)
            cell.toolTip = item.certificate.details
            return cell
        default: return probeLabel(item.checkedAt.map(Self.format) ?? "—", size: 12, color: .secondaryLabelColor)
        }
    }
    private static func format(_ date: Date) -> String { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter.string(from: date) }
    @objc private func detect() { probes.detect() }
    @objc private func downloadSelected() {
        guard probes.rows.indices.contains(table.selectedRow) else { return }
        probes.download(names: [probes.rows[table.selectedRow].name])
    }
    @objc private func downloadAll() { probes.download(names: probes.rows.map(\.name)) }
}

final class ChainWindowController: NSWindowController {
    private let entry = NSPopUpButton()
    private let exit = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "启用链式代理", target: nil, action: nil)
    private let status = probeLabel("正在读取节点…", size: 12, color: .secondaryLabelColor)
    private let save = NSButton(title: "保存并应用", target: nil, action: nil)
    var onSaved: (() -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 390),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Amyfree · 链式代理"; window.isReleasedWhenClosed = false
        super.init(window: window)
        save.target = self; save.action = #selector(apply); save.bezelStyle = .rounded; save.isEnabled = false
        save.keyEquivalent = "\r"
        let root = probeStack([probeLabel("链式代理", size: 25, weight: .semibold),
                               probeLabel("流量先经过入口，再由出口连接目标网站。", color: .secondaryLabelColor),
                               enabled,
                               probeStack([probeLabel("入口节点", size: 12, color: .secondaryLabelColor), entry], spacing: 5),
                               probeLabel("↓", size: 18, color: .systemBlue),
                               probeStack([probeLabel("出口节点", size: 12, color: .secondaryLabelColor), exit], spacing: 5),
                               status, save,
                               probeLabel("只影响走代理的流量，直连和拦截规则保留；开启后可在节点测速中检测整条链路。", size: 12, color: .secondaryLabelColor)], spacing: 10)
        let content = window.contentView!; content.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                     root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        window.center(); load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    private func load() {
        DispatchQueue.global(qos: .utility).async {
            let result = run(AppRuntime.python, ["\(CFG_DIR)/chain_proxy.py", "status", "--home", CFG_DIR], timeout: 10)
            let data = result.out.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard result.status == 0, let object = data, let names = object["names"] as? [String] else {
                    self.status.stringValue = data?["error"] as? String ?? "无法读取节点，请先添加订阅。"; return
                }
                self.entry.addItems(withTitles: names); self.exit.addItems(withTitles: names)
                if let name = object["entry"] as? String, names.contains(name) { self.entry.selectItem(withTitle: name) }
                if let name = object["exit"] as? String, names.contains(name) { self.exit.selectItem(withTitle: name) }
                else if names.count > 1 { self.exit.selectItem(at: 1) }
                self.enabled.state = object["enabled"] as? Bool == true ? .on : .off
                self.save.isEnabled = names.count > 1
                self.status.stringValue = names.count < 2 ? "至少需要两个代理节点。" : self.enabled.state == .on ? "链式代理已开启。" : "链式代理未开启。选择入口和出口后保存。"
            }
        }
    }
    @objc private func apply() {
        guard let first = entry.titleOfSelectedItem, let last = exit.titleOfSelectedItem else { return }
        if enabled.state == .on && first == last { status.stringValue = "入口和出口请选择不同的节点。"; status.textColor = .systemRed; return }
        let action = enabled.state == .on ? "enable" : "disable"
        [save, entry, exit, enabled].forEach { $0.isEnabled = false }
        status.stringValue = "正在校验并应用链式设置…"; status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(AppRuntime.python, ["\(CFG_DIR)/chain_proxy.py", action, "--home", CFG_DIR, "--entry", first, "--exit", last], timeout: 90)
            let data = result.out.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                [self.save, self.entry, self.exit, self.enabled].forEach { $0.isEnabled = true }
                if result.status == 0 {
                    self.status.stringValue = data?["applied"] as? Bool == true ? "已保存并应用。新连接使用更新后的链路。" : "已保存，下次启动代理时生效。"
                    self.status.textColor = .systemGreen; self.onSaved?()
                } else { self.status.stringValue = data?["error"] as? String ?? "链式设置失败，请检查配置。"; self.status.textColor = .systemRed }
            }
        }
    }
}
