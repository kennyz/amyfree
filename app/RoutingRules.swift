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
    guard semaphore.wait(timeout: .now() + 12) == .success else { throw RoutingError(tr("内核响应超时，请稍后重试。", "The core timed out. Please try again later.")) }
    if let failure = failure { throw RoutingError(tr("无法连接代理内核：", "Could not reach the proxy core: ") + failure.localizedDescription) }
    guard (200..<300).contains(status) else { throw RoutingError(tr("内核未接受分流设置（HTTP \(status)）。", "The core rejected the routing settings (HTTP \(status)).")) }
    return responseData
}

func makeRoutingStore() -> RoutingStore {
    RoutingStore(directory: URL(fileURLWithPath: CFG_DIR, isDirectory: true), validate: { candidate in
        let binary = "\(CFG_DIR)/mihomo"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw RoutingError(tr("尚未安装 mihomo 内核，无法检查分流配置。", "The mihomo core isn't installed, so the routing config can't be checked.")) }
        let result = run(binary, ["-t", "-d", CFG_DIR, "-f", candidate.path], timeout: 25)
        guard result.status == 0 else {
            var detail = result.out.replacingOccurrences(of: apiSecret().isEmpty ? "__API_SECRET__" : apiSecret(), with: tr("[密钥]", "[secret]"))
            detail = detail.replacingOccurrences(of: "https?://[^\\s\"']+", with: tr("[地址]", "[url]"), options: .regularExpression)
            throw RoutingError(result.status == -2 ? tr("配置检查超时，本次未保存。", "Config check timed out; nothing was saved.") : tr("配置检查未通过，本次未保存。", "Config check failed; nothing was saved.") + "\n\(detail.suffix(700))")
        }
    }, apply: { path, state in
        let expected = try RoutingDocument(yaml: String(contentsOf: path, encoding: .utf8))
        _ = try routingRequest("PUT", "/configs?force=true", body: ["path": path.path])
        let data = try routingRequest("GET", "/rules")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let rules = object?["rules"] as? [[String: Any]], rules.count == expected.ruleTexts.count,
              rules.last?["proxy"] as? String == state.fallback else {
            throw RoutingError(tr("内核返回的规则与保存内容不一致。", "The rules reported by the core don't match what was saved."))
        }
        for (index, text) in expected.ruleTexts.enumerated() {
            let parts = text.split(separator: ",").map(String.init)
            if parts.count >= 3, ["DOMAIN", "DOMAIN-SUFFIX", "GEOSITE", "GEOIP", "IP-CIDR"].contains(parts[0]) {
                guard rules[index]["proxy"] as? String == parts[2] else { throw RoutingError(tr("内核中的连接方式未更新。", "The policy in the core wasn't updated.")) }
                if ["DOMAIN", "DOMAIN-SUFFIX", "GEOSITE"].contains(parts[0]) {
                    guard rules[index]["payload"] as? String == parts[1] else { throw RoutingError(tr("内核中的匹配目标未更新。", "The match target in the core wasn't updated.")) }
                }
            }
        }
        let configs = try JSONSerialization.jsonObject(with: routingRequest("GET", "/configs")) as? [String: Any]
        guard configs?["mode"] as? String == expected.mode else { throw RoutingError(tr("代理的运行模式未更新。", "The proxy mode wasn't updated.")) }
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
    private let china = NSButton(checkboxWithTitle: tr("国内网站直连", "Direct for China sites"), target: nil, action: nil)
    private let ads = NSButton(checkboxWithTitle: tr("拦截常见广告", "Block common ads"), target: nil, action: nil)
    private let fallback = NSPopUpButton()
    private let table = NSTableView()
    private let empty = label(tr("还没有自定义规则\n添加一个网站，为它单独选择连接方式。", "No custom rules yet\nAdd a website to choose how it connects."), color: .secondaryLabelColor)
    private let status = label("", size: 12, color: .secondaryLabelColor)
    private let count = label("", size: 12, color: .secondaryLabelColor)
    private let save = NSButton(title: tr("保存并应用", "Save & Apply"), target: nil, action: nil)
    private let edit = NSButton(title: tr("编辑", "Edit"), target: nil, action: nil)
    private let remove = NSButton(title: tr("删除", "Delete"), target: nil, action: nil)
    private let up = NSButton(title: tr("上移", "Move Up"), target: nil, action: nil)
    private let down = NSButton(title: tr("下移", "Move Down"), target: nil, action: nil)
    private let previous = NSButton(title: tr("还原上次", "Restore Previous"), target: nil, action: nil)
    private var controls: [NSControl] = []
    private let testField = NSTextField()
    private let testButton = NSButton(title: tr("测试", "Test"), target: nil, action: nil)
    private let testResult = label(tr("输入网址，查看它命中哪条规则、经由哪个出口，以及能否访问。",
                                      "Enter a URL to see which rule it matches, which exit it uses, and whether it loads."),
                                   size: 12, color: .secondaryLabelColor)
    private var testing = false
    private let tabs = NSTabView()
    private let basicsTab = NSTabViewItem(identifier: "basics")
    private let customTab = NSTabViewItem(identifier: "custom")
    private var dirty: Bool { state != initial }

    init(store: RoutingStore) throws {
        let document = try store.load()
        self.store = store; source = document.source; state = document.state; initial = document.state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = tr("Amyfree · 分流设置", "Amyfree · Routing Rules")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        synchronize()
        status.stringValue = isRunning ? tr("已读取当前规则。修改后点击保存并应用。", "Current rules loaded. Make changes, then click Save & Apply.") : tr("代理未启动，保存的设置将在下次启动时生效。", "The proxy is off; saved settings apply next time it starts.")
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
        let header = stack([icon, stack([label(tr("分流设置", "Routing Rules"), size: 25, weight: .semibold),
                                             label(tr("为每个网站，选择合适的连接方式。", "Choose how each website connects."), color: .secondaryLabelColor)], spacing: 5)], vertical: false, spacing: 14)
        root.addArrangedSubview(header)

        china.target = self; china.action = #selector(settingsChanged)
        ads.target = self; ads.action = #selector(settingsChanged)
        fallback.target = self; fallback.action = #selector(settingsChanged)
        for policy in [RulePolicy.proxy, .manual, .direct] {
            fallback.addItem(withTitle: policy.title)
            fallback.lastItem?.representedObject = policy.rawValue
        }
        if !["PROXY", "手动选择", "DIRECT"].contains(state.fallback) {
            fallback.addItem(withTitle: tr("现有策略 · ", "Existing policy · ") + state.fallback)
            fallback.lastItem?.representedObject = state.fallback
        }
        fallback.widthAnchor.constraint(equalToConstant: 205).isActive = true
        let basic = stack([
            stack([china, label(tr("国内网站与国内 IP 不经过代理。", "China sites and IPs bypass the proxy."), size: 12, color: .secondaryLabelColor)], spacing: 3),
            stack([ads, label(tr("通过广告域名规则拦截常见广告。", "Block common ads using ad-domain rules."), size: 12, color: .secondaryLabelColor)], spacing: 3),
            stack([label(tr("其他流量", "Other traffic"), weight: .medium), fallback], vertical: false, spacing: 14),
            label(tr("局域网与本机始终直连，NAS 和本地服务可正常访问。", "LAN and localhost always connect directly, so NAS and local services keep working."), size: 12, color: .secondaryLabelColor)
        ], spacing: 12)
        controls += [china, ads, fallback]

        let add = NSButton(title: tr("添加规则…", "Add Rule…"), target: nil, action: nil)
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
        target.title = tr("匹配目标", "Match"); target.width = 450; target.minWidth = 350
        let policy = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("policy"))
        policy.title = tr("连接方式", "Policy"); policy.width = 175; policy.minWidth = 160
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
            list.heightAnchor.constraint(equalToConstant: 200),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -24)
        ])
        let custom = stack([label(tr("从上到下匹配，优先于基础分流；局域网直连除外。", "Matched top to bottom, before the basics (LAN direct always wins)."), size: 12, color: .secondaryLabelColor),
                            toolbar, list, count], spacing: 10)
        for view in [toolbar, list] { view.widthAnchor.constraint(equalTo: custom.widthAnchor).isActive = true }

        // 基础分流与自定义规则分页显示；地址测试放在分页下方，两页都能用
        for (item, content, title) in [(basicsTab, basic, tr("基础分流", "Basics")), (customTab, custom, tr("自定义规则", "Custom Rules"))] {
            let page = NSView()
            page.addSubview(content)
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 16),
                content.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -16),
                content.topAnchor.constraint(equalTo: page.topAnchor, constant: 14),
                content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -14)
            ])
            item.label = title; item.view = page
            tabs.addTabViewItem(item)
        }
        tabs.heightAnchor.constraint(equalToConstant: 350).isActive = true
        root.addArrangedSubview(tabs)

        testField.placeholderString = tr("例如 github.com 或 https://www.google.com", "e.g. github.com or https://www.google.com")
        testField.target = self; testField.action = #selector(testURL)
        testButton.target = self; testButton.action = #selector(testURL); testButton.bezelStyle = .rounded
        testButton.setContentHuggingPriority(.required, for: .horizontal)
        testResult.maximumNumberOfLines = 4
        testResult.isSelectable = true
        let testRow = stack([testField, testButton], vertical: false, spacing: 8)
        let test = stack([label(tr("地址测试", "URL Test"), size: 15, weight: .semibold), testRow, testResult], spacing: 10)
        for view in [testRow, testResult] { view.widthAnchor.constraint(equalTo: test.widthAnchor).isActive = true }
        root.addArrangedSubview(card(test))

        let recommended = NSButton(title: tr("恢复推荐", "Restore Defaults"), target: nil, action: nil)
        let close = NSButton(title: tr("关闭", "Close"), target: nil, action: nil)
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
            fallback.addItem(withTitle: tr("现有策略 · ", "Existing policy · ") + state.fallback)
            fallback.lastItem?.representedObject = state.fallback
        }
        if let item = fallback.itemArray.first(where: { $0.representedObject as? String == state.fallback }) { fallback.select(item) }
        table.reloadData()
        empty.isHidden = !state.entries.isEmpty
        customTab.label = tr("自定义规则（\(state.entries.count)）", "Custom Rules (\(state.entries.count))")
        let advanced = state.entries.filter { $0.userRule == nil }.count
        count.stringValue = tr("\(state.entries.count) 条规则", "\(state.entries.count) rules") + (advanced > 0 ? tr(" · \(advanced) 条高级规则原样保留，可删除或调整顺序", " · \(advanced) advanced rules kept as-is (can be deleted or reordered)") : tr(" · 代理使用菜单中的节点策略", " · proxy uses the node chosen in the menu"))
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

    private func changed(_ message: String = tr("有未保存的修改。点击「保存并应用」使设置生效。", "Unsaved changes. Click Save & Apply to make them take effect.")) {
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
            let text = entry.userRule?.policy.title ?? tr("高级策略", "Advanced policy")
            let color: NSColor = entry.userRule?.policy == .direct ? .systemGreen : entry.userRule?.policy == .reject ? .systemRed : .systemBlue
            return label(text, size: 12, weight: .medium, color: color)
        }
        let title = label(entry.userRule?.value ?? entry.text, weight: .medium)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingMiddle
        let subtitle = label(entry.userRule?.kind.title ?? tr("高级规则 · 保留原格式", "Advanced rule · kept as-is"), size: 11, color: .secondaryLabelColor)
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
            }) { throw RoutingError(tr("这个匹配目标已有规则，请编辑现有规则。", "A rule for this target already exists. Edit that rule instead.")) }
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
        changed(tr("已恢复基础推荐设置，自定义规则保留。点击保存并应用。", "Basics restored to defaults; custom rules kept. Click Save & Apply."))
    }
    @objc private func restorePrevious() {
        do { state = try store.previousState(); changed(tr("已载入上次保存前的规则。点击保存并应用完成还原。", "Loaded the rules from before the last save. Click Save & Apply to restore them.")) }
        catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
    @objc private func closeSettings() { window?.performClose(nil) }

    // MARK: 地址测试

    @objc private func testURL() {
        guard !testing else { return }
        guard let url = RouteTester.normalize(testField.stringValue) else {
            showTest(tr("请输入有效网址，例如 github.com。", "Enter a valid URL, e.g. github.com."), color: .systemRed); return
        }
        guard isRunning else {
            showTest(tr("代理未启动。启用代理后才能测试。", "The proxy is off. Turn it on to test."), color: .systemRed); return
        }
        testing = true; testButton.isEnabled = false
        showTest(tr("正在经代理访问 ", "Requesting via the proxy: ") + url.absoluteString + "…", color: .secondaryLabelColor)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RouteTester.run(url)
            DispatchQueue.main.async {
                self.testing = false; self.testButton.isEnabled = true
                self.present(result)
            }
        }
    }

    private func showTest(_ text: String, color: NSColor) {
        testResult.stringValue = text; testResult.textColor = color
    }

    private func present(_ result: RouteTestResult) {
        var lines: [String] = []
        if let match = result.match {
            lines.append(tr("规则：", "Rule: ") + describeRule(match))
            lines.append(tr("出口：", "Exit: ") + describeExit(match))
            // 命中自定义规则时切到自定义规则页并选中它
            if let type = match.ruleType,
               let index = state.entries.firstIndex(where: { $0.text.hasPrefix("\(type),\(match.payload),") }) {
                tabs.selectTabViewItem(customTab)
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index)
            }
        } else {
            lines.append(tr("内核日志中没有这次连接的记录（需要 config.yaml 中 log-level 为 info 或 debug）。",
                            "The core didn't log this connection (needs log-level info or debug in config.yaml)."))
        }
        let time = String(format: "%.2f s", result.elapsed)
        let blocked = result.match?.policy == "REJECT"
        if let status = result.status {
            lines.append(tr("结果：HTTP \(status) · \(time)", "Result: HTTP \(status) · \(time)"))
        } else if let upstream = result.match?.dialError {
            lines.append(tr("结果：节点连接失败 · ", "Result: node connection failed · ") + upstream)
        } else if !blocked {
            lines.append(tr("结果：访问失败 · ", "Result: request failed · ") + (result.error ?? "") + " · \(time)")
        }
        if dirty { lines.append(tr("未保存的修改不参与测试，保存后再测。", "Unsaved changes aren't included; save, then test again.")) }
        let color: NSColor = result.status != nil ? .systemGreen : blocked ? .secondaryLabelColor : .systemRed
        showTest(lines.joined(separator: "\n"), color: color)
    }

    private func describeRule(_ match: RouteMatch) -> String {
        switch (match.rule, match.payload) {
        case ("Match", _): return tr("其他流量（兜底规则）", "Other traffic (fallback rule)")
        case ("GeoSite", "cn"), ("GeoIP", "CN"): return tr("国内网站直连", "Direct for China sites") + " · \(match.rule) \(match.payload)"
        case ("GeoSite", "category-ads-all"): return tr("拦截常见广告", "Block common ads") + " · GeoSite \(match.payload)"
        case ("GeoSite", "private"), ("GeoIP", "private"): return tr("局域网与本机", "LAN and localhost") + " · \(match.rule) \(match.payload)"
        default:
            if let type = match.ruleType { return tr("自定义规则 · ", "Custom rule · ") + "\(type) \(match.payload)" }
            return match.payload.isEmpty ? match.rule : "\(match.rule) \(match.payload)"
        }
    }

    private func describeExit(_ match: RouteMatch) -> String {
        switch match.policy {
        case "DIRECT": return tr("直连", "Direct")
        case "REJECT", "REJECT-DROP": return tr("拦截（请求被阻止）", "Blocked (request rejected)")
        default:
            let policy = RulePolicy(rawValue: match.policy)?.title ?? match.policy
            guard let node = match.node, !node.isEmpty else { return policy }
            return policy + " → " + (node == "MIMIO_CHAIN_EXIT" ? tr("链式代理", "Chain proxy") : node)
        }
    }

    @objc private func saveSettings() {
        guard dirty && !saving else { return }
        saving = true; onSaving?(true)
        status.stringValue = tr("正在检查并保存规则…", "Checking and saving rules…")
        status.textColor = .secondaryLabelColor
        save.title = tr("保存中…", "Saving…")
        updateButtons()
        let draft = state
        let expected = source
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.store.save(draft, expectedSource: expected) }
            DispatchQueue.main.async {
                self.saving = false; self.onSaving?(false); self.save.title = tr("保存并应用", "Save & Apply")
                switch result {
                case .success(let saved):
                    self.source = saved.source
                    self.state = (try? RoutingDocument(yaml: saved.source).state) ?? draft
                    self.initial = self.state
                    self.status.stringValue = saved.applied ? tr("已保存并生效。新连接将使用这些规则。", "Saved and applied. New connections use these rules.") : tr("已保存。代理下次启动时将使用这些规则。", "Saved. The proxy uses these rules next time it starts.")
                    self.status.textColor = .systemGreen
                case .failure(let error):
                    self.status.stringValue = tr("保存失败，修改仍保留在窗口中。", "Save failed; your changes are still in the window.")
                    self.status.textColor = .systemRed
                    let alert = NSAlert()
                    alert.messageText = tr("分流设置未保存", "Routing rules not saved")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: tr("继续编辑", "Keep Editing"))
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
        alert.messageText = tr("还有未保存的修改", "You have unsaved changes")
        alert.informativeText = tr("可以继续编辑并保存，或放弃本次修改。", "Keep editing and save, or discard the changes.")
        alert.addButton(withTitle: tr("继续编辑", "Keep Editing"))
        alert.addButton(withTitle: tr("放弃修改", "Discard Changes"))
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
        window.title = initial == nil ? tr("添加分流规则", "Add Routing Rule") : tr("编辑分流规则", "Edit Routing Rule")
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
        let cancel = NSButton(title: tr("取消", "Cancel"), target: self, action: #selector(cancelEditing))
        let confirm = NSButton(title: initial == nil ? tr("添加", "Add") : tr("完成", "Done"), target: self, action: #selector(confirmEditing))
        cancel.bezelStyle = .rounded; confirm.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"; confirm.keyEquivalent = "\r"
        let footer = stack([NSView(), cancel, confirm], vertical: false)
        footer.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        confirm.setContentHuggingPriority(.required, for: .horizontal)
        let root = stack([label(initial == nil ? tr("添加一条规则", "Add a rule") : tr("编辑这条规则", "Edit this rule"), size: 20, weight: .semibold),
                          stack([label(tr("匹配范围", "Match type"), size: 12, color: .secondaryLabelColor), kind], spacing: 4),
                          field, hint,
                          stack([label(tr("连接方式", "Policy"), size: 12, color: .secondaryLabelColor), policy], spacing: 4),
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
        field.placeholderString = network ? tr("例如 192.168.1.0/24 或 8.8.8.8", "e.g. 192.168.1.0/24 or 8.8.8.8") : tr("例如 example.com，也可以粘贴完整网址", "e.g. example.com, or paste a full URL")
        hint.stringValue = network ? tr("单个 IP 会自动转换为只匹配该地址的网段。", "A single IP becomes a range matching only that address.") : kind.selectedItem?.representedObject as? String == RuleKind.suffix.rawValue ? tr("example.com 会同时匹配它的所有子域名。", "example.com also matches all its subdomains.") : tr("只匹配填写的域名，不包含其他子域名。", "Matches only this exact domain, not its subdomains.")
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
