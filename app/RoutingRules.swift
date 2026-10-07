import AppKit

private func routingRequest(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Data {
    var request = URLRequest(url: URL(string: "http://\(API)\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 10
    let secret = apiSecret()
    if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
    if let body = body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let semaphore = DispatchSemaphore(value: 0)
    var responseData = Data()
    var status = 0
    var failure: Error?
    session.dataTask(with: request) { data, response, error in
        responseData = data ?? Data()
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        failure = error
        semaphore.signal()
    }.resume()
    guard semaphore.wait(timeout: .now() + 12) == .success else { throw RoutingError("内核响应超时，请稍后重试。") }
    if let failure = failure { throw RoutingError("无法连接代理内核：\(failure.localizedDescription)") }
    guard (200..<300).contains(status) else { throw RoutingError("内核未接受分流设置（HTTP \(status)）。") }
    return responseData
}

func makeRoutingStore() -> RoutingStore {
    RoutingStore(directory: URL(fileURLWithPath: CFG_DIR, isDirectory: true), validate: { candidate in
        let binary = "\(CFG_DIR)/mihomo"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw RoutingError("尚未安装 mihomo 内核，无法检查分流配置。") }
        let result = run(binary, ["-t", "-d", CFG_DIR, "-f", candidate.path], timeout: 25)
        guard result.status == 0 else {
            var detail = result.out.replacingOccurrences(of: apiSecret().isEmpty ? "__API_SECRET__" : apiSecret(), with: "[密钥]")
            detail = detail.replacingOccurrences(of: "https?://[^\\s\"']+", with: "[地址]", options: .regularExpression)
            throw RoutingError(result.status == -2 ? "配置检查超时，本次未保存。" : "配置检查未通过，本次未保存。\n\(detail.suffix(700))")
        }
    }, apply: { path, state in
        let expected = try RoutingDocument(yaml: String(contentsOf: path, encoding: .utf8))
        _ = try routingRequest("PUT", "/configs?force=true", body: ["path": path.path])
        let data = try routingRequest("GET", "/rules")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let rules = object?["rules"] as? [[String: Any]], rules.count == expected.ruleTexts.count,
              rules.last?["proxy"] as? String == state.fallback else {
            throw RoutingError("内核返回的规则与保存内容不一致。")
        }
        for (index, text) in expected.ruleTexts.enumerated() {
            let parts = text.split(separator: ",").map(String.init)
            if parts.count >= 3, ["DOMAIN", "DOMAIN-SUFFIX", "GEOSITE", "GEOIP", "IP-CIDR"].contains(parts[0]) {
                guard rules[index]["proxy"] as? String == parts[2] else { throw RoutingError("内核中的连接方式未更新。") }
                if ["DOMAIN", "DOMAIN-SUFFIX", "GEOSITE"].contains(parts[0]) {
                    guard rules[index]["payload"] as? String == parts[1] else { throw RoutingError("内核中的匹配目标未更新。") }
                }
            }
        }
        let configs = try JSONSerialization.jsonObject(with: routingRequest("GET", "/configs")) as? [String: Any]
        guard configs?["mode"] as? String == expected.mode else { throw RoutingError("代理的运行模式未更新。") }
    }, running: { isRunning })
}

private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.maximumNumberOfLines = 2
    return field
}

private func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 10) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY
    stack.spacing = spacing
    return stack
}

private func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

private func card(_ content: NSView) -> NSBox {
    let box = NSBox()
    box.boxType = .custom
    box.borderWidth = 1
    box.borderColor = .separatorColor
    box.fillColor = .controlBackgroundColor
    box.cornerRadius = 12
    box.contentViewMargins = NSSize(width: 0, height: 0)
    box.contentView!.addSubview(content)
    pin(content, to: box.contentView!, inset: 18)
    return box
}

final class RoutingWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store: RoutingStore
    private var source: String
    private var initial: RoutingState
    private var state: RoutingState
    private var saving = false
    private var discardOnClose = false
    private var editor: RoutingRuleEditor?
    var onSaving: ((Bool) -> Void)?
    private let china = NSButton(checkboxWithTitle: "国内网站直连", target: nil, action: nil)
    private let ads = NSButton(checkboxWithTitle: "拦截常见广告", target: nil, action: nil)
    private let fallback = NSPopUpButton()
    private let table = NSTableView()
    private let empty = label("还没有自定义规则\n添加一个网站，为它单独选择连接方式。", color: .secondaryLabelColor)
    private let status = label("", size: 12, color: .secondaryLabelColor)
    private let count = label("", size: 12, color: .secondaryLabelColor)
    private let save = NSButton(title: "保存并应用", target: nil, action: nil)
    private let edit = NSButton(title: "编辑", target: nil, action: nil)
    private let remove = NSButton(title: "删除", target: nil, action: nil)
    private let up = NSButton(title: "上移", target: nil, action: nil)
    private let down = NSButton(title: "下移", target: nil, action: nil)
    private let previous = NSButton(title: "还原上次", target: nil, action: nil)
    private var controls: [NSControl] = []
    private var dirty: Bool { state != initial }

    init(store: RoutingStore) throws {
        let document = try store.load()
        self.store = store; source = document.source; state = document.state; initial = document.state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 730),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Amyfree · 分流设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        synchronize()
        status.stringValue = isRunning ? "已读取当前规则。修改后点击保存并应用。" : "代理未启动，保存的设置将在下次启动时生效。"
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bind(_ button: NSButton, _ action: Selector) {
        button.target = self; button.action = action; button.bezelStyle = .rounded
        controls.append(button)
    }

    private func build() {
        let root = stack([], spacing: 18)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 54).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let header = stack([icon, stack([label("分流设置", size: 25, weight: .semibold),
                                             label("为每个网站，选择合适的连接方式。", color: .secondaryLabelColor)], spacing: 5)], vertical: false, spacing: 14)
        root.addArrangedSubview(header)

        china.target = self; china.action = #selector(settingsChanged)
        ads.target = self; ads.action = #selector(settingsChanged)
        fallback.target = self; fallback.action = #selector(settingsChanged)
        for policy in [RulePolicy.proxy, .manual, .direct] {
            fallback.addItem(withTitle: policy.title)
            fallback.lastItem?.representedObject = policy.rawValue
        }
        if !["PROXY", "手动选择", "DIRECT"].contains(state.fallback) {
            fallback.addItem(withTitle: "现有策略 · \(state.fallback)")
            fallback.lastItem?.representedObject = state.fallback
        }
        fallback.widthAnchor.constraint(equalToConstant: 205).isActive = true
        let basic = stack([
            label("基础分流", size: 15, weight: .semibold),
            stack([china, label("国内网站与国内 IP 不经过代理。", size: 12, color: .secondaryLabelColor)], spacing: 3),
            stack([ads, label("通过广告域名规则拦截常见广告。", size: 12, color: .secondaryLabelColor)], spacing: 3),
            stack([label("其他流量", weight: .medium), fallback], vertical: false, spacing: 14),
            label("局域网与本机始终直连，NAS 和本地服务可正常访问。", size: 12, color: .secondaryLabelColor)
        ], spacing: 12)
        root.addArrangedSubview(card(basic))
        controls += [china, ads, fallback]

        let add = NSButton(title: "添加规则…", target: nil, action: nil)
        bind(add, #selector(addRule)); bind(edit, #selector(editRule)); bind(remove, #selector(deleteRule))
        bind(up, #selector(moveRuleUp)); bind(down, #selector(moveRuleDown))
        let toolbar = stack([add, edit, remove, NSView(), up, down], vertical: false, spacing: 8)
        toolbar.arrangedSubviews[3].setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [add, edit, remove, up, down] { button.setContentHuggingPriority(.required, for: .horizontal) }
        table.dataSource = self; table.delegate = self
        table.rowHeight = 48
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(editRule)
        let target = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
        target.title = "匹配目标"; target.width = 450; target.minWidth = 350
        let policy = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("policy"))
        policy.title = "连接方式"; policy.width = 175; policy.minWidth = 160
        table.addTableColumn(target); table.addTableColumn(policy)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let list = NSView()
        list.addSubview(scroll); pin(scroll, to: list)
        list.addSubview(empty)
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.heightAnchor.constraint(equalToConstant: 170),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -24)
        ])
        let custom = stack([label("自定义规则", size: 15, weight: .semibold),
                            label("从上到下匹配，优先于基础分流；局域网直连除外。", size: 12, color: .secondaryLabelColor),
                            toolbar, list, count], spacing: 10)
        for view in [toolbar, list] { view.widthAnchor.constraint(equalTo: custom.widthAnchor).isActive = true }
        root.addArrangedSubview(card(custom))

        let recommended = NSButton(title: "恢复推荐", target: nil, action: nil)
        let close = NSButton(title: "关闭", target: nil, action: nil)
        bind(recommended, #selector(restoreRecommended)); bind(previous, #selector(restorePrevious))
        bind(close, #selector(closeSettings)); bind(save, #selector(saveSettings))
        save.keyEquivalent = "\r"
        let footer = stack([recommended, previous, NSView(), close, save], vertical: false, spacing: 8)
        footer.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [recommended, previous, close, save] { button.setContentHuggingPriority(.required, for: .horizontal) }
        root.addArrangedSubview(status)
        root.addArrangedSubview(footer)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let content = window!.contentView!
        content.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        window?.initialFirstResponder = china
    }

    private func synchronize() {
        china.state = state.chinaDirect ? .on : .off
        ads.state = state.blockAds ? .on : .off
        if !fallback.itemArray.contains(where: { $0.representedObject as? String == state.fallback }) {
            fallback.addItem(withTitle: "现有策略 · \(state.fallback)")
            fallback.lastItem?.representedObject = state.fallback
        }
        if let item = fallback.itemArray.first(where: { $0.representedObject as? String == state.fallback }) { fallback.select(item) }
        table.reloadData()
        empty.isHidden = !state.entries.isEmpty
        let advanced = state.entries.filter { $0.userRule == nil }.count
        count.stringValue = "\(state.entries.count) 条规则" + (advanced > 0 ? " · \(advanced) 条高级规则原样保留，可删除或调整顺序" : " · 代理使用菜单中的节点策略")
        updateButtons()
    }

    private func updateButtons() {
        controls.forEach { $0.isEnabled = !saving }
        save.isEnabled = dirty && !saving
        previous.isEnabled = !saving && FileManager.default.fileExists(atPath: store.backupURL.path)
        let index = table.selectedRow
        let selected = state.entries.indices.contains(index)
        edit.isEnabled = !saving && selected && state.entries[index].userRule != nil
        remove.isEnabled = !saving && selected
        up.isEnabled = !saving && selected && index > 0
        down.isEnabled = !saving && selected && index < state.entries.count - 1
        window?.isDocumentEdited = dirty
    }

    private func changed(_ message: String = "有未保存的修改。点击「保存并应用」使设置生效。") {
        status.stringValue = message
        status.textColor = .secondaryLabelColor
        synchronize()
    }

    @objc private func settingsChanged() {
        state.chinaDirect = china.state == .on
        state.blockAds = ads.state == .on
        state.fallback = fallback.selectedItem?.representedObject as? String ?? "PROXY"
        changed()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { state.entries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = state.entries[row]
        if tableColumn?.identifier.rawValue == "policy" {
            let text = entry.userRule?.policy.title ?? "高级策略"
            let color: NSColor = entry.userRule?.policy == .direct ? .systemGreen : entry.userRule?.policy == .reject ? .systemRed : .systemBlue
            return label(text, size: 12, weight: .medium, color: color)
        }
        let title = label(entry.userRule?.value ?? entry.text, weight: .medium)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingMiddle
        let subtitle = label(entry.userRule?.kind.title ?? "高级规则 · 保留原格式", size: 11, color: .secondaryLabelColor)
        return stack([title, subtitle], spacing: 2)
    }

    @objc private func addRule() { openEditor(index: nil) }
    @objc private func editRule() {
        let index = table.selectedRow
        guard state.entries.indices.contains(index), state.entries[index].userRule != nil else { return }
        openEditor(index: index)
    }
    private func openEditor(index: Int?) {
        guard !saving else { return }
        editor = RoutingRuleEditor(initial: index.map { state.entries[$0].userRule! }, submit: { [weak self] rule in
            guard let self = self else { return }
            if self.state.entries.enumerated().contains(where: { item in
                item.offset != index && item.element.userRule?.kind == rule.kind && item.element.userRule?.value == rule.value
            }) { throw RoutingError("这个匹配目标已有规则，请编辑现有规则。") }
            let target: Int
            if let index = index { self.state.entries[index] = RoutingEntry(rule: rule); target = index }
            else { self.state.entries.append(RoutingEntry(rule: rule)); target = self.state.entries.count - 1 }
            self.changed()
            self.table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        }, finished: { [weak self] in self?.editor = nil })
        window!.beginSheet(editor!.window!)
    }
    @objc private func deleteRule() {
        let index = table.selectedRow
        guard !saving, state.entries.indices.contains(index) else { return }
        state.entries.remove(at: index); changed()
    }
    private func move(_ offset: Int) {
        let index = table.selectedRow
        guard !saving, state.entries.indices.contains(index), state.entries.indices.contains(index + offset) else { return }
        state.entries.swapAt(index, index + offset)
        changed()
        table.selectRowIndexes(IndexSet(integer: index + offset), byExtendingSelection: false)
    }
    @objc private func moveRuleUp() { move(-1) }
    @objc private func moveRuleDown() { move(1) }
    @objc private func restoreRecommended() {
        state.chinaDirect = true; state.blockAds = true; state.fallback = "PROXY"
        changed("已恢复基础推荐设置，自定义规则保留。点击保存并应用。")
    }
    @objc private func restorePrevious() {
        do { state = try store.previousState(); changed("已载入上次保存前的规则。点击保存并应用完成还原。") }
        catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
    @objc private func closeSettings() { window?.performClose(nil) }

    @objc private func saveSettings() {
        guard dirty && !saving else { return }
        saving = true; onSaving?(true)
        status.stringValue = "正在检查并保存规则…"
        status.textColor = .secondaryLabelColor
        save.title = "保存中…"
        updateButtons()
        let draft = state
        let expected = source
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.store.save(draft, expectedSource: expected) }
            DispatchQueue.main.async {
                self.saving = false; self.onSaving?(false); self.save.title = "保存并应用"
                switch result {
                case .success(let saved):
                    self.source = saved.source
                    self.state = (try? RoutingDocument(yaml: saved.source).state) ?? draft
                    self.initial = self.state
                    self.status.stringValue = saved.applied ? "已保存并生效。新连接将使用这些规则。" : "已保存。代理下次启动时将使用这些规则。"
                    self.status.textColor = .systemGreen
                case .failure(let error):
                    self.status.stringValue = "保存失败，修改仍保留在窗口中。"
                    self.status.textColor = .systemRed
                    let alert = NSAlert()
                    alert.messageText = "分流设置未保存"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "继续编辑")
                    alert.beginSheetModal(for: self.window!)
                }
                self.synchronize()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !saving else { return false }
        if !dirty || discardOnClose { return true }
        let alert = NSAlert()
        alert.messageText = "还有未保存的修改"
        alert.informativeText = "可以继续编辑并保存，或放弃本次修改。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        alert.beginSheetModal(for: sender) { response in
            if response == .alertSecondButtonReturn { self.discardOnClose = true; sender.performClose(nil) }
        }
        return false
    }
}

private final class RoutingRuleEditor: NSWindowController {
    private let kind = NSPopUpButton()
    private let field = NSTextField()
    private let policy = NSPopUpButton()
    private let hint = label("", size: 12, color: .secondaryLabelColor)
    private let errorLabel = label("", size: 12, color: .systemRed)
    private let submit: (UserRule) throws -> Void
    private let finished: () -> Void
    private let originalNoResolve: Bool

    init(initial: UserRule?, submit: @escaping (UserRule) throws -> Void, finished: @escaping () -> Void) {
        self.submit = submit; self.finished = finished
        originalNoResolve = initial?.noResolve ?? false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 345),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = initial == nil ? "添加分流规则" : "编辑分流规则"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        for value in RuleKind.allCases { kind.addItem(withTitle: value.title); kind.lastItem?.representedObject = value.rawValue }
        for value in RulePolicy.allCases { policy.addItem(withTitle: value.title); policy.lastItem?.representedObject = value.rawValue }
        if let initial = initial {
            kind.selectItem(withTitle: initial.kind.title)
            field.stringValue = initial.value
            policy.selectItem(withTitle: initial.policy.title)
        }
        kind.target = self; kind.action = #selector(kindChanged)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditing))
        let confirm = NSButton(title: initial == nil ? "添加" : "完成", target: self, action: #selector(confirmEditing))
        cancel.bezelStyle = .rounded; confirm.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"; confirm.keyEquivalent = "\r"
        let footer = stack([NSView(), cancel, confirm], vertical: false)
        footer.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        confirm.setContentHuggingPriority(.required, for: .horizontal)
        let root = stack([label(initial == nil ? "添加一条规则" : "编辑这条规则", size: 20, weight: .semibold),
                          stack([label("匹配范围", size: 12, color: .secondaryLabelColor), kind], spacing: 4),
                          field, hint,
                          stack([label("连接方式", size: 12, color: .secondaryLabelColor), policy], spacing: 4),
                          errorLabel, footer], spacing: 10)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        window.contentView!.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22)
        ])
        window.initialFirstResponder = field
        kindChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func kindChanged() {
        let network = kind.selectedItem?.representedObject as? String == RuleKind.network.rawValue
        field.placeholderString = network ? "例如 192.168.1.0/24 或 8.8.8.8" : "例如 example.com，也可以粘贴完整网址"
        hint.stringValue = network ? "单个 IP 会自动转换为只匹配该地址的网段。" : kind.selectedItem?.representedObject as? String == RuleKind.suffix.rawValue ? "example.com 会同时匹配它的所有子域名。" : "只匹配填写的域名，不包含其他子域名。"
        errorLabel.stringValue = ""
    }
    @objc private func confirmEditing() {
        do {
            var rule = try UserRule.make(kind: RuleKind(rawValue: kind.selectedItem!.representedObject as! String)!,
                                         input: field.stringValue,
                                         policy: RulePolicy(rawValue: policy.selectedItem!.representedObject as! String)!)
            rule.noResolve = rule.kind == .network && originalNoResolve
            try submit(rule)
            finish()
        } catch { errorLabel.stringValue = error.localizedDescription; window?.makeFirstResponder(field) }
    }
    @objc private func cancelEditing() { finish() }
    private func finish() {
        if let parent = window?.sheetParent { parent.endSheet(window!) }
        window?.orderOut(nil)
        finished()
    }
}
