import Foundation
import Darwin

struct RoutingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum RuleKind: String, CaseIterable {
    case suffix = "DOMAIN-SUFFIX", domain = "DOMAIN", network = "IP-CIDR"
    var title: String {
        switch self {
        case .suffix: return tr("网站及其子域名", "Site and subdomains")
        case .domain: return tr("仅此域名", "This domain only")
        case .network: return tr("IP 地址 / 网段", "IP address / range")
        }
    }
}

enum RulePolicy: String, CaseIterable {
    case proxy = "PROXY", direct = "DIRECT", reject = "REJECT", manual = "手动选择"
    var title: String {
        switch self {
        case .proxy: return tr("代理 · 自动选择", "Proxy · Auto")
        case .direct: return tr("直连", "Direct")
        case .reject: return tr("拦截", "Block")
        case .manual: return tr("代理 · 手动选择", "Proxy · Manual")
        }
    }
}

struct UserRule: Equatable {
    var kind: RuleKind
    var value: String
    var policy: RulePolicy
    var noResolve = false
    var text: String { "\(kind.rawValue),\(value),\(policy.rawValue)" + (noResolve ? ",no-resolve" : "") }

    static func make(kind: RuleKind, input: String, policy: RulePolicy) throws -> UserRule {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RoutingError(tr("请填写网站地址或 IP 网段。", "Enter a website or IP range.")) }
        guard !value.contains(where: { $0.isNewline || $0 == "," || $0 == "#" || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw RoutingError(tr("地址不能包含换行、逗号或 #。", "The address can't contain line breaks, commas or #."))
        }
        if kind == .network {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw RoutingError(tr("请输入有效 IP 网段，例如 192.168.1.0/24。", "Enter a valid IP range, e.g. 192.168.1.0/24.")) }
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            let address = String(parts[0])
            let bits: Int
            if inet_pton(AF_INET, address, &ipv4) == 1 { bits = 32 }
            else if inet_pton(AF_INET6, address, &ipv6) == 1 { bits = 128 }
            else { throw RoutingError(tr("IP 地址不正确，例如 192.168.1.0/24 或 2001:db8::/32。", "Invalid IP address, e.g. 192.168.1.0/24 or 2001:db8::/32.")) }
            let mask = parts.count == 2 ? Int(parts[1]) : bits
            guard let mask = mask, (0...bits).contains(mask) else { throw RoutingError(tr("网段长度不正确，IPv4 为 0–32，IPv6 为 0–128。", "Invalid prefix length: 0–32 for IPv4, 0–128 for IPv6.")) }
            value = "\(address.lowercased())/\(mask)"
            return UserRule(kind: kind, value: value, policy: policy)
        }
        if kind == .suffix, value.hasPrefix("*.") { value.removeFirst(2) }
        if kind == .suffix, value.hasPrefix(".") { value.removeFirst() }
        guard let url = URL(string: value.contains("://") ? value : "https://\(value)"),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, var host = url.host else {
            throw RoutingError(tr("请输入网站域名或网址，例如 example.com。", "Enter a domain or URL, e.g. example.com."))
        }
        host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let valid = !labels.isEmpty && host.utf8.count <= 253 && labels.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        var ipv4 = in_addr()
        guard valid, inet_pton(AF_INET, host, &ipv4) != 1 else {
            throw RoutingError(tr("请输入正确域名；IP 地址请选择「IP 地址 / 网段」。", "Enter a valid domain; for IP addresses choose \"IP address / range\"."))
        }
        return UserRule(kind: kind, value: host, policy: policy)
    }
}

struct RoutingEntry: Equatable {
    let text: String
    let originalLine: String?
    var userRule: UserRule? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard (3...4).contains(parts.count), let kind = RuleKind(rawValue: parts[0]),
              let policy = RulePolicy(rawValue: parts[2]),
              parts.count == 3 || (kind == .network && parts[3] == "no-resolve") else { return nil }
        return UserRule(kind: kind, value: parts[1], policy: policy, noResolve: parts.count == 4)
    }
    init(rule: UserRule) { text = rule.text; originalLine = nil }
    init(text: String, line: String? = nil) { self.text = text; originalLine = line }
    var yaml: String { originalLine ?? "  - '\(text.replacingOccurrences(of: "'", with: "''"))'" }
}

struct RoutingState: Equatable {
    var chinaDirect = true
    var blockAds = true
    var fallback = "PROXY"
    var entries: [RoutingEntry] = []
    var ruleTexts: [String] {
        var rules = ["GEOSITE,private,DIRECT", "GEOIP,private,DIRECT,no-resolve"]
        rules += entries.map(\.text)
        if blockAds { rules.append("GEOSITE,category-ads-all,REJECT") }
        if chinaDirect { rules += ["GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT"] }
        rules.append("MATCH,\(fallback)")
        return rules
    }
}

struct RoutingDocument {
    let source: String
    private let prefix: [String]
    private let suffix: [String]
    private let comments: [String]
    let state: RoutingState
    let ruleTexts: [String]
    let mode: String

    init(yaml: String) throws {
        source = yaml
        let lines = yaml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let modeLine = lines.first { $0.hasPrefix("mode:") } ?? "mode: rule"
        mode = String(modeLine.dropFirst(5)).components(separatedBy: " #")[0]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'\""))).lowercased()
        let headers = lines.indices.filter { lines[$0].range(of: "^rules:\\s*(?:#.*)?$", options: .regularExpression) != nil }
        guard headers.count == 1, let start = headers.first else {
            throw RoutingError(tr("此配置的规则格式暂不支持可视化编辑。请使用 rules 下的逐行规则列表。", "This config's rule format can't be edited visually. Use a line-by-line list under rules."))
        }
        var end = start + 1
        while end < lines.count {
            if lines[end].range(of: "^[A-Za-z0-9_-]+\\s*:", options: .regularExpression) != nil { break }
            end += 1
        }
        prefix = Array(lines[..<start])
        suffix = Array(lines[end...])
        var preservedComments: [String] = []
        var entries: [RoutingEntry] = []
        for line in lines[(start + 1)..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("#") { preservedComments.append(line) }
                continue
            }
            guard trimmed.hasPrefix("- ") else { throw RoutingError(tr("发现复杂 YAML 规则格式。为保留原配置，本次不会改写。", "Found complex YAML rule syntax. The config was left unchanged to preserve it.")) }
            let scalar = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let text: String
            if scalar.hasPrefix("'") {
                // YAML 单引号的转义为两个单引号；保留原行的注释。
                var result = ""
                var index = scalar.index(after: scalar.startIndex)
                var closed = false
                while index < scalar.endIndex {
                    let character = scalar[index]
                    let next = scalar.index(after: index)
                    if character == "'" {
                        if next < scalar.endIndex, scalar[next] == "'" { result.append("'"); index = scalar.index(after: next); continue }
                        let tail = scalar[next...].trimmingCharacters(in: .whitespaces)
                        guard tail.isEmpty || tail.hasPrefix("#") else { throw RoutingError(tr("规则引号后存在无法识别的内容。", "Unrecognized content after a quoted rule.")) }
                        closed = true; break
                    }
                    result.append(character); index = next
                }
                guard closed else { throw RoutingError(tr("规则中有未闭合的引号。", "A rule has an unclosed quote.")) }
                text = result
            } else if scalar.hasPrefix("\"") {
                var escaped = false
                var closing: String.Index?
                for index in scalar.indices.dropFirst() {
                    if escaped { escaped = false; continue }
                    if scalar[index] == "\\" { escaped = true; continue }
                    if scalar[index] == "\"" { closing = index; break }
                }
                guard let closing = closing,
                      let data = String(scalar[...closing]).data(using: .utf8),
                      let value = try? JSONDecoder().decode(String.self, from: data) else {
                    throw RoutingError(tr("此规则的引号格式暂不支持编辑。", "This rule's quoting can't be edited yet."))
                }
                let tail = scalar[scalar.index(after: closing)...].trimmingCharacters(in: .whitespaces)
                guard tail.isEmpty || tail.hasPrefix("#") else { throw RoutingError(tr("规则引号后存在无法识别的内容。", "Unrecognized content after a quoted rule.")) }
                text = value
            } else {
                text = scalar.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("[") && !text.hasPrefix("{") && !text.hasPrefix("*") && !text.hasPrefix("&") else {
                    throw RoutingError(tr("此配置使用了高级 YAML 写法，暂不支持可视化编辑。", "This config uses advanced YAML and can't be edited visually."))
                }
            }
            entries.append(RoutingEntry(text: text, line: line))
        }
        let matches = entries.indices.filter { entries[$0].text.hasPrefix("MATCH,") }
        guard matches.count == 1, matches.first == entries.indices.last,
              entries.last!.text.split(separator: ",").count == 2 else {
            throw RoutingError(tr("配置需要在规则列表末尾保留一条 MATCH 兜底规则。", "The rule list must end with a MATCH fallback rule."))
        }
        let fallback = String(entries.last!.text.dropFirst(6))
        ruleTexts = entries.map(\.text)
        let controlled: Set<String> = ["GEOSITE,private,DIRECT", "GEOIP,private,DIRECT,no-resolve", "GEOIP,private,DIRECT",
                                       "GEOSITE,category-ads-all,REJECT", "GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT", "GEOIP,CN,DIRECT,no-resolve",
                                       "GEOSITE,geolocation-!cn,\(fallback)", "MATCH,\(fallback)"]
        state = RoutingState(chinaDirect: entries.contains { ["GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT", "GEOIP,CN,DIRECT,no-resolve"].contains($0.text) },
                             blockAds: entries.contains { $0.text == "GEOSITE,category-ads-all,REJECT" },
                             fallback: fallback, entries: entries.filter { !controlled.contains($0.text) })
        comments = preservedComments
    }

    func render(_ state: RoutingState) -> String {
        var rules = ["rules:"] + comments + ["  - GEOSITE,private,DIRECT", "  - GEOIP,private,DIRECT,no-resolve"]
        rules += state.entries.map(\.yaml)
        if state.blockAds { rules.append("  - GEOSITE,category-ads-all,REJECT") }
        if state.chinaDirect { rules += ["  - GEOSITE,cn,DIRECT", "  - GEOIP,CN,DIRECT"] }
        rules.append("  - 'MATCH,\(state.fallback.replacingOccurrences(of: "'", with: "''"))'")
        var rendered = prefix + rules + suffix
        if let mode = rendered.firstIndex(where: { $0.hasPrefix("mode:") }) { rendered[mode] = "mode: rule" }
        else { rendered.insert("mode: rule", at: 0) }
        return rendered.joined(separator: "\n")
    }
}

/// 验证和内核 API 由调用方注入，事务和规则模型可在隔离目录独立验证。
final class RoutingStore {
    let directory: URL
    private let validate: (URL) throws -> Void
    private let apply: (URL, RoutingState) throws -> Void
    private let running: () -> Bool
    var configURL: URL { directory.appendingPathComponent("config.yaml") }
    var backupURL: URL { directory.appendingPathComponent(".mimio-rules-backup.yaml") }

    init(directory: URL, validate: @escaping (URL) throws -> Void,
         apply: @escaping (URL, RoutingState) throws -> Void, running: @escaping () -> Bool) {
        self.directory = directory; self.validate = validate; self.apply = apply; self.running = running
    }

    func load() throws -> RoutingDocument { try RoutingDocument(yaml: String(contentsOf: configURL, encoding: .utf8)) }
    func previousState() throws -> RoutingState { try RoutingDocument(yaml: String(contentsOf: backupURL, encoding: .utf8)).state }

    @discardableResult
    func save(_ state: RoutingState, expectedSource: String) throws -> (source: String, applied: Bool) {
        let document = try load()
        guard document.source == expectedSource else { throw RoutingError(tr("配置已被其他操作修改。请关闭并重新打开分流设置后再试。", "The config was changed elsewhere. Close and reopen Routing Rules, then try again.")) }
        let updated = document.render(state)
        let secretURL = directory.appendingPathComponent(".api-secret")
        let secret = (try? String(contentsOf: secretURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let runtime = secret.isEmpty ? updated : updated.replacingOccurrences(of: "__API_SECRET__", with: secret)
        let candidate = directory.appendingPathComponent(".mimio-validate-\(UUID().uuidString).yaml")
        try write(Data(runtime.utf8), to: candidate)
        defer { try? FileManager.default.removeItem(at: candidate) }
        try validate(candidate)
        // 校验耗时期间也可能被另一个窗口/订阅操作修改，提交前再检查一次。
        guard try String(contentsOf: configURL, encoding: .utf8) == expectedSource else {
            throw RoutingError(tr("校验期间配置发生了变化，本次修改未保存。请重新打开设置。", "The config changed during validation, so nothing was saved. Reopen the settings."))
        }
        let runtimeURL = directory.appendingPathComponent(".run-config.yaml")
        let notun = directory.appendingPathComponent(".config.yaml.notun")
        var updates: [(URL, Data)] = [(configURL, Data(updated.utf8)), (runtimeURL, Data(runtime.utf8)), (backupURL, Data(document.source.utf8))]
        if FileManager.default.fileExists(atPath: notun.path) {
            let old = try RoutingDocument(yaml: String(contentsOf: notun, encoding: .utf8))
            updates.append((notun, Data(old.render(state).utf8)))
        }
        let originals = try updates.map { url, _ -> (URL, Data?) in
            (url, FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
        }
        let wasRunning = running()
        var reloadAttempted = false
        do {
            for (url, data) in updates { try write(data, to: url) }
            if wasRunning { reloadAttempted = true; try apply(runtimeURL, state) }
        } catch {
            var rollbackErrors: [String] = []
            for (url, data) in originals {
                do {
                    if let data = data { try write(data, to: url) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { rollbackErrors.append(url.lastPathComponent) }
            }
            // 若 API 在失败前已接收新配置，还原运行中的规则。
            if reloadAttempted {
                do {
                    if !FileManager.default.fileExists(atPath: runtimeURL.path) {
                        let oldRuntime = secret.isEmpty ? document.source : document.source.replacingOccurrences(of: "__API_SECRET__", with: secret)
                        try write(Data(oldRuntime.utf8), to: runtimeURL)
                    }
                    try apply(runtimeURL, document.state)
                } catch { rollbackErrors.append(tr("运行中的规则", "running rules")) }
            }
            if !rollbackErrors.isEmpty {
                throw RoutingError(tr("保存失败，以下内容未能自动还原：\(rollbackErrors.joined(separator: "、"))。请重新加载原配置。", "Save failed and these could not be restored automatically: \(rollbackErrors.joined(separator: ", ")). Reload the original config.") + "\n" + error.localizedDescription)
            }
            throw RoutingError(tr("修改未生效，已还原原配置。", "The change did not take effect; the original config was restored.") + "\n" + error.localizedDescription)
        }
        return (updated, wasRunning)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
