import AppKit
import UniformTypeIdentifiers

/// 节点管理：新建节点，或编辑现有节点（默认选中当前节点）。可用表单或源码（链接 / YAML / JSON）编辑，
/// 两种方式互相同步。保存由 node_manager.py 校验并即时重载。
final class NodeManagerWindowController: NSWindowController {
    private let picker = NSPopUpButton()
    private let origin = probeLabel("", size: 12, color: .secondaryLabelColor)
    private let mode = NSSegmentedControl(labels: [tr("表单", "Form"), tr("源码", "Source")], trackingMode: .selectOne, target: nil, action: nil)
    private let typePicker = NSPopUpButton()
    private let fields = NodeFormField.all
    private var controls: [NSView] = []
    private let grid = NSGridView()
    // 系统配置好的可滚动文本视图；手工创建的 NSTextView 初始宽度为 0，文字无法显示。
    private let editorScroll = NSTextView.scrollableTextView()
    private var editor: NSTextView { editorScroll.documentView as! NSTextView }
    private let source = NSStackView()
    private let spacer = NSView()
    private var root = NSStackView()
    private let status = probeLabel(tr("正在读取节点…", "Reading nodes…"), size: 12, color: .secondaryLabelColor)
    private let save = NSButton(title: tr("保存并应用", "Save & Apply"), target: nil, action: nil)
    private let remove = NSButton(title: tr("删除节点", "Delete Node"), target: nil, action: nil)
    private let fromLink = NSButton(title: tr("从链接添加…", "From Link…"), target: nil, action: nil)
    private let fromQR = NSButton(title: tr("从二维码图片添加…", "From QR Code Image…"), target: nil, action: nil)
    private var origins: [String: String] = [:]
    private var preferred: String?
    private var formBase: [String: Any] = [:]   // 表单未覆盖的字段从这里保留
    private static let modeKey = "AmyfreeNodeEditorMode"
    var onSaved: (() -> Void)?

    init(selecting name: String?) {
        preferred = name
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Amyfree · 节点管理", "Amyfree · Node Management"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 300)
        super.init(window: window)
        picker.target = self; picker.action = #selector(pick)
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mode.target = self; mode.action = #selector(switchMode)
        mode.selectedSegment = UserDefaults.standard.integer(forKey: Self.modeKey) == 1 ? 1 : 0
        save.target = self; save.action = #selector(apply); save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        remove.target = self; remove.action = #selector(deleteNode); remove.bezelStyle = .rounded
        fromLink.target = self; fromLink.action = #selector(importLink); fromLink.bezelStyle = .rounded
        fromQR.target = self; fromQR.action = #selector(importQRCode); fromQR.bezelStyle = .rounded
        buildForm(); buildSource()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        root = probeStack([probeLabel(tr("添加新节点或编辑当前节点；手工改动在更新订阅后保留。", "Add a node or edit the current one. Your changes are kept when the subscription updates."), color: .secondaryLabelColor),
                               probeStack([probeStack([picker, mode], vertical: false, spacing: 12), origin], spacing: 5),
                               probeStack([formLabel(tr("快速添加", "Quick add")), fromLink, fromQR], vertical: false, spacing: 8),
                               grid, source, spacer, status,
                               probeStack([save, remove], vertical: false, spacing: 10)], spacing: 10)
        let content = window.contentView!; content.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                     root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                                     root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
        showMode()
        fitWindow(); window.center(); load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    private var selectedName: String? { picker.selectedItem?.representedObject as? String }
    private var formMode: Bool { mode.selectedSegment == 0 }

    // MARK: 布局

    private func buildForm() {
        typePicker.addItems(withTitles: NodeFormField.types)
        typePicker.target = self; typePicker.action = #selector(updateVisibility)
        var rows: [[NSView]] = [[formLabel(tr("协议", "Protocol")), typePicker]]
        for field in fields {
            let control: NSView
            switch field.kind {
            case .toggle: control = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            case .choice(let options):
                let popup = NSPopUpButton(); popup.addItems(withTitles: options)
                popup.target = self; popup.action = #selector(updateVisibility); control = popup
            case .combo(let options):
                let combo = NSComboBox(); combo.addItems(withObjectValues: options); combo.completes = true; control = combo
            case .text, .number:
                let text = NSTextField(); text.lineBreakMode = .byTruncatingTail
                if field.kind == .number { text.placeholderString = field.path == ["port"] ? "443" : "0" }
                control = text
            }
            controls.append(control)
            rows.append([formLabel(field.title), control])
        }
        // 表单的 NSGridView 每行一个字段，按协议隐藏不适用的行。
        rows.forEach { grid.addRow(with: $0) }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline; grid.rowSpacing = 6; grid.columnSpacing = 12
        grid.column(at: 0).width = 110
    }

    private func buildSource() {
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = NSSize(width: 4, height: 6)
        let scroll = editorScroll
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let hint = probeLabel(tr("粘贴 vless:// vmess:// ss:// trojan:// 链接，或单个节点的 Clash YAML/JSON。", "Paste a vless:// vmess:// ss:// trojan:// link, or one node's Clash YAML/JSON."), size: 12, color: .secondaryLabelColor)
        [scroll, hint].forEach { source.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: source.widthAnchor).isActive = true }
        source.orientation = .vertical; source.alignment = .leading; source.spacing = 6
        source.setContentHuggingPriority(.init(1), for: .vertical)
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        return label
    }

    /// 窗口高度贴合内容：表单按当前协议显示的字段伸缩，源码保留编辑区最小高度；保持顶边不动。
    private func fitWindow() {
        guard let window = window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height + 44
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content.frame.width, height: height))
        var frame = window.frame
        guard abs(frame.height - target.height) > 1 else { return }
        frame.origin.y += frame.height - target.height
        frame.size.height = target.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func showMode() {
        grid.isHidden = !formMode; spacer.isHidden = !formMode; source.isHidden = formMode
        UserDefaults.standard.set(mode.selectedSegment, forKey: Self.modeKey)
        fitWindow()
    }

    // MARK: 表单读写

    private func fill(_ node: [String: Any]) {
        formBase = node
        let type = node["type"] as? String ?? "vless"
        if typePicker.itemTitles.contains(type) == false { typePicker.addItem(withTitle: type) }
        typePicker.selectItem(withTitle: type)
        for (field, control) in zip(fields, controls) {
            let text = field.display(in: node)
            switch control {
            case let button as NSButton where !(control is NSPopUpButton): button.state = text == "true" ? .on : .off
            case let popup as NSPopUpButton: popup.selectItem(withTitle: text.isEmpty ? popup.itemTitles.first ?? "" : text)
                if popup.indexOfSelectedItem < 0 { popup.addItem(withTitle: text); popup.selectItem(withTitle: text) }
            case let field as NSTextField: field.stringValue = text
            default: break
            }
        }
        updateVisibility()
    }

    private func formValues() -> [Int: String] {
        var values: [Int: String] = [:]
        for (index, control) in controls.enumerated() {
            switch control {
            case let popup as NSPopUpButton: values[index] = popup.titleOfSelectedItem ?? ""
            case let button as NSButton: values[index] = button.state == .on ? "true" : ""
            case let field as NSTextField: values[index] = field.stringValue
            default: break
            }
        }
        return values
    }

    private func formNode() -> [String: Any] {
        buildNode(base: formBase, type: typePicker.titleOfSelectedItem ?? "vless", values: formValues())
    }

    @objc private func updateVisibility() {
        let type = typePicker.titleOfSelectedItem ?? ""
        let network = (fields.firstIndex { $0.path == ["network"] }.flatMap { controls[$0] as? NSPopUpButton })?.titleOfSelectedItem ?? "tcp"
        for (index, field) in fields.enumerated() { grid.row(at: index + 1).isHidden = !field.visible(type: type, network: network) }
        if formMode { fitWindow() }
    }

    private static let newNode: [String: Any] = ["type": "vless", "port": 443, "network": "tcp", "tls": true, "udp": true]

    // MARK: 同步与保存

    private func helper(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 10) -> (ok: Bool, object: [String: Any]?) {
        let result = run(AppRuntime.helper(in: CFG_DIR), ["node-manager"] + arguments + ["--home", CFG_DIR], timeout: timeout, input: input)
        let object = result.out.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (result.status == 0 && object != nil, object)
    }

    private func json(_ node: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// 切换前把当前视图的内容转换到另一侧；源码无法解析时留在源码视图。
    @objc private func switchMode() {
        let toForm = formMode
        let input = toForm ? editor.string : json(formNode())
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.helper(["parse"], input: input)
            DispatchQueue.main.async {
                self.setBusy(false)
                guard result.ok, let node = result.object?["node"] as? [String: Any] else {
                    self.mode.selectedSegment = toForm ? 1 : 0
                    self.show(result.object?["error"] as? String ?? tr("无法转换节点配置。", "Could not convert the node config."), color: .systemRed); return
                }
                if toForm { self.fill(node.isEmpty ? Self.newNode : node) }
                else { self.editor.string = result.object?["config"] as? String ?? "" }
                self.show(""); self.showMode()
            }
        }
    }

    private func load(select name: String? = nil, message: String? = nil) {
        setBusy(true)
        DispatchQueue.global(qos: .utility).async {
            let result = self.helper(["status"])
            DispatchQueue.main.async {
                self.setBusy(false)
                guard result.ok, let nodes = result.object?["nodes"] as? [[String: Any]] else {
                    self.show(result.object?["error"] as? String ?? tr("无法读取节点。", "Could not read nodes."), color: .systemRed); return
                }
                self.picker.removeAllItems()
                self.picker.addItem(withTitle: tr("＋ 新建节点", "+ New Node"))
                self.picker.menu?.addItem(.separator())
                self.origins = [:]
                for node in nodes {
                    guard let title = node["name"] as? String else { continue }
                    self.origins[title] = node["origin"] as? String
                    self.picker.addItem(withTitle: title)
                    self.picker.lastItem?.representedObject = title
                }
                let target = name ?? self.preferred
                self.preferred = nil
                if let target = target, let index = self.picker.itemArray.firstIndex(where: { $0.representedObject as? String == target }) {
                    self.picker.selectItem(at: index)
                }
                self.pick()
                if let message = message { self.show(message, color: .systemGreen) }
                else { self.show(nodes.isEmpty ? tr("还没有节点，可填写表单或粘贴节点链接新建。", "No nodes yet. Fill in the form or paste a node link to add one.") : "") }
            }
        }
    }

    @objc private func pick() {
        let kind = selectedName.flatMap { origins[$0] }
        origin.stringValue = [nil: tr("新节点保存后加入「选择节点」列表。", "A new node joins the Select Node list once saved."),
                              "subscription": tr("来自订阅。保存后作为自定义版本覆盖订阅中的同名节点。", "From the subscription. Saving keeps your edited version in place of the subscription's."),
                              "edited": tr("订阅节点（已编辑）。可恢复为订阅版本。", "Subscription node (edited). Can be restored to the subscription version."),
                              "added": tr("手工添加的节点。", "Manually added node.")][kind] ?? ""
        remove.title = kind == "edited" ? tr("恢复订阅版本", "Restore Subscription Version") : tr("删除节点", "Delete Node")
        remove.isHidden = kind == nil || kind == "subscription"
        guard let name = selectedName else {
            fill(Self.newNode); editor.string = ""
            window?.makeFirstResponder(formMode ? controls.first : editor); return
        }
        editor.string = ""; fill([:])
        DispatchQueue.global(qos: .utility).async {
            let result = self.helper(["get", "--name", name])
            DispatchQueue.main.async {
                guard self.selectedName == name else { return }
                guard result.ok, let node = result.object?["node"] as? [String: Any] else {
                    self.show(result.object?["error"] as? String ?? tr("无法读取节点。", "Could not read the node."), color: .systemRed); return
                }
                self.fill(node)
                self.editor.string = result.object?["config"] as? String ?? ""
            }
        }
    }

    @objc private func apply() {
        let original = selectedName ?? ""
        let text = formMode ? json(formNode()) : editor.string
        setBusy(true); show(tr("正在校验并应用节点…", "Checking and applying the node…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.helper(["save", "--name", original], input: text, timeout: 60)
            DispatchQueue.main.async {
                self.setBusy(false)
                guard result.ok, let name = result.object?["name"] as? String else {
                    self.show(result.object?["error"] as? String ?? tr("保存失败，请检查节点配置。", "Save failed. Check the node config."), color: .systemRed); return
                }
                self.onSaved?()
                self.load(select: name, message: self.outcome(result.object, done: tr("已保存。", "Saved.")))
            }
        }
    }

    @objc private func deleteNode() {
        guard let name = selectedName else { return }
        let restoring = origins[name] == "edited"
        let alert = NSAlert()
        alert.messageText = restoring ? tr("恢复「\(name)」的订阅版本？", "Restore the subscription version of “\(name)”?") : tr("删除节点「\(name)」？", "Delete node “\(name)”?")
        alert.addButton(withTitle: restoring ? tr("恢复", "Restore") : tr("删除", "Delete"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.helper(["delete", "--name", name], timeout: 60)
            DispatchQueue.main.async {
                self.setBusy(false)
                guard result.ok else {
                    self.show(result.object?["error"] as? String ?? tr("操作失败。", "The operation failed."), color: .systemRed); return
                }
                self.onSaved?()
                self.load(select: restoring ? name : nil,
                          message: self.outcome(result.object, done: restoring ? tr("已恢复订阅版本。", "Restored the subscription version.") : tr("已删除。", "Deleted.")))
            }
        }
    }

    // MARK: 链接 / 二维码导入

    @objc private func importLink() {
        let alert = NSAlert()
        alert.messageText = tr("从链接添加节点", "Add Node from Link")
        alert.informativeText = tr("粘贴 vless:// vmess:// ss:// trojan:// 分享链接。", "Paste a vless:// vmess:// ss:// trojan:// share link.")
        alert.addButton(withTitle: tr("导入", "Import")); alert.addButton(withTitle: tr("取消", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "vless://…"; field.lineBreakMode = .byTruncatingMiddle
        // 剪贴板里正好是节点链接时直接填入
        if let clip = NSPasteboard.general.string(forType: .string), case .link(let link) = nodeLink(in: [clip]) { field.stringValue = link }
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        importText([field.stringValue], from: tr("链接", "link"))
    }

    @objc private func importQRCode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = tr("选择包含节点二维码的图片", "Choose an image containing a node QR code")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let codes = decodeQRCodes(at: url)
        if codes.isEmpty { show(tr("图片中未识别到二维码，请换一张更清晰的图片。", "No QR code found in the image. Try a clearer image."), color: .systemRed); return }
        importText(codes, from: tr("二维码", "QR code"))
    }

    /// 导入的链接填入「新建节点」的表单和源码，检查后再保存。
    private func importText(_ texts: [String], from kind: String) {
        let link: String
        switch nodeLink(in: texts) {
        case .link(let value): link = value
        case .subscription:
            show(tr("这是订阅地址，请在「节点与订阅 → 修改订阅地址」中使用。", "This is a subscription URL. Use it in Nodes & Subscription → Edit Subscription URL."), color: .systemRed); return
        case .unsupported:
            show(tr("未找到支持的节点链接（vless/vmess/ss/trojan）。", "No supported node link found (vless/vmess/ss/trojan)."), color: .systemRed); return
        }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.helper(["parse"], input: link)
            DispatchQueue.main.async {
                self.setBusy(false)
                guard result.ok, let node = result.object?["node"] as? [String: Any], !node.isEmpty else {
                    self.show(result.object?["error"] as? String ?? tr("无法解析节点链接。", "Could not parse the node link."), color: .systemRed); return
                }
                self.picker.selectItem(at: 0); self.pick()
                self.fill(node)
                self.editor.string = result.object?["config"] as? String ?? link
                self.show(tr("已从\(kind)读取节点「\(node["name"] as? String ?? "")」，检查后点击「保存并应用」。", "Read node “\(node["name"] as? String ?? "")” from the \(kind). Review it, then click Save & Apply."), color: .systemBlue)
            }
        }
    }

    private func outcome(_ object: [String: Any]?, done: String) -> String {
        done + (object?["applied"] as? Bool == true ? tr("已即时生效，新连接使用更新后的节点。", " Applied; new connections use the updated nodes.")
                                                    : tr("下次启动代理时生效。", " Takes effect next time the proxy starts."))
    }

    private func setBusy(_ busy: Bool) {
        ([save, remove, picker, mode, typePicker, fromLink, fromQR] as [NSControl]).forEach { $0.isEnabled = !busy }
        editor.isEditable = !busy
    }
    private func show(_ text: String, color: NSColor = .secondaryLabelColor) { status.stringValue = text; status.textColor = color }
}
