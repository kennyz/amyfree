import Foundation

enum NodeIndicator: String {
    case unknown, testing, good, slow, failed, paused
    static func quality(delay: Int) -> NodeIndicator { delay <= 0 ? .failed : delay <= 300 ? .good : .slow }
    var title: String {
        switch self {
        case .unknown: return "未检测"
        case .testing: return "检测中"
        case .good: return "可用"
        case .slow: return "较慢"
        case .failed: return "检测失败"
        case .paused: return "服务暂停"
        }
    }
}

struct NodeCertificate {
    var state = "unknown"
    var expires: Date?
    var days: Int?
    var reason = "尚未检测证书"
    init() {}
    init(_ data: [String: Any]) {
        state = data["state"] as? String ?? "unknown"
        expires = (data["not_after"] as? Double).map { Date(timeIntervalSince1970: $0) }
        days = data["days_left"] as? Int
        reason = data["reason"] as? String ?? ""
    }
    var indicator: NodeIndicator {
        switch state {
        case "valid": return .good
        case "expiring": return .slow
        case "expired", "not_yet_valid", "untrusted": return .failed
        default: return .unknown
        }
    }
    var text: String {
        switch state {
        case "valid": return "剩余 \(days ?? 0) 天"
        case "expiring": return "即将到期 · \(days ?? 0) 天"
        case "expired": return "已过期"
        case "not_yet_valid": return "尚未生效"
        case "untrusted": return "校验未通过 · \(days ?? 0) 天"
        case "not_applicable": return reason.contains("REALITY") ? "REALITY · 不适用" : "无 TLS · 不适用"
        case "unsupported": return "QUIC · 暂不支持"
        default: return "无法确认"
        }
    }
    var details: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return [expires.map { "到期时间：\(formatter.string(from: $0))" }, reason.isEmpty ? nil : reason].compactMap { $0 }.joined(separator: "\n")
    }
}

struct NodeMeasurement {
    let name: String
    var title: String
    var indicator: NodeIndicator = .unknown
    var delay: Int?
    var megabytesPerSecond: Double?
    var checkedAt: Date?
    var downloadedAt: Date?
    var downloading = false
    var downloadError = false
    var certificate = NodeCertificate()
    var delayText: String { delay.map { "\($0) ms" } ?? "—" }
    var speedText: String {
        if downloading { return "测速中…" }
        if downloadError { return "未完成" }
        return megabytesPerSecond.map { String(format: "%.2f MB/s", $0) } ?? "未测速"
    }
    var visibleIndicator: NodeIndicator { downloading ? .testing : indicator }
}

protocol NodeProbeBackend {
    func perform(_ arguments: [String]) throws -> [String: Any]
    func fingerprint() -> String
    func cancel()
}

/// 所有状态在主线程提交；工作在后台完成，菜单关闭时定时器仍运行。
final class NodeProbeCoordinator {
    static let interval: TimeInterval = 30
    let backend: NodeProbeBackend
    private(set) var rows: [NodeMeasurement] = []
    private(set) var checking = false
    private(set) var downloading = false
    private(set) var roundCount = 0
    private(set) var lastCheck: Date?
    private(set) var message = "正在读取订阅节点…"
    private(set) var chain: [String: Any] = [:]
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var stopped = false
    private var generation = ""

    init(backend: NodeProbeBackend) { self.backend = backend }
    func start() {
        stopped = false
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.detect() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        detect()
    }
    func stop() { stopped = true; timer?.invalidate(); timer = nil; backend.cancel() }

    @discardableResult
    func detect() -> Bool {
        guard !stopped, !checking, !downloading else { return false }
        checking = true
        rows.indices.forEach { rows[$0].indicator = .testing }
        message = "正在检测延迟与可用性…"
        onChange?()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.backend.perform(["--latency"]) }
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                self.checking = false
                self.roundCount += 1
                switch result {
                case .success(let data):
                    let fingerprint = data["fingerprint"] as? String ?? ""
                    if fingerprint != self.backend.fingerprint() {
                        self.rows = []; self.message = "订阅已变化，正在重新检测…"
                        self.onChange?(); self.detect(); return
                    }
                    self.applyCatalogue(data)
                    let paused = data["paused"] as? Bool ?? false
                    let results = data["results"] as? [[String: Any]] ?? []
                    let mapping = Dictionary(results.compactMap { result -> (String, [String: Any])? in
                        guard let name = result["name"] as? String else { return nil }; return (name, result)
                    }, uniquingKeysWith: { _, new in new })
                    let now = Date()
                    let certificates = data["certificates"] as? [String: [String: Any]] ?? [:]
                    for index in self.rows.indices {
                        if let certificate = certificates[self.rows[index].name] { self.rows[index].certificate = NodeCertificate(certificate) }
                        if paused {
                            self.rows[index].indicator = .paused; self.rows[index].delay = nil
                        } else if let result = mapping[self.rows[index].name] {
                            let delay = result["delay"] as? Int ?? 0
                            self.rows[index].indicator = (result["service_error"] as? Bool == true) ? .unknown : NodeIndicator.quality(delay: delay)
                            self.rows[index].delay = delay > 0 ? delay : nil
                            self.rows[index].checkedAt = now
                        }
                    }
                    self.lastCheck = now
                    self.message = paused ? "代理未启动，自动检测暂停；仍可手工测下载速度。" : "已完成第 \(self.roundCount) 轮检测 · 每 30 秒自动检测"
                case .failure(let error):
                    self.rows.indices.forEach { self.rows[$0].indicator = .unknown }
                    self.message = error.localizedDescription
                }
                self.onChange?()
            }
        }
        return true
    }

    private func applyCatalogue(_ data: [String: Any]) {
        let fingerprint = data["fingerprint"] as? String ?? ""
        let previous = generation == fingerprint ? Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { old, _ in old }) : [:]
        let labels = data["labels"] as? [String: String] ?? [:]
        rows = (data["names"] as? [String] ?? []).map { name in
            var row = previous[name] ?? NodeMeasurement(name: name, title: labels[name] ?? name)
            row.title = labels[name] ?? name
            return row
        }
        chain = data["chain"] as? [String: Any] ?? [:]
        generation = fingerprint
    }

    @discardableResult
    func download(names: [String]) -> Bool {
        guard !stopped, !checking, !downloading, !names.isEmpty else { return false }
        let requested = names.filter { name in rows.contains { $0.name == name } }
        guard !requested.isEmpty else { return false }
        downloading = true
        let expected = generation
        for index in rows.indices where requested.contains(rows[index].name) { rows[index].downloading = true; rows[index].downloadError = false }
        message = "正在进行实际下载测速…"
        onChange?()
        DispatchQueue.global(qos: .utility).async {
            for (position, name) in requested.enumerated() {
                if self.backend.fingerprint() != expected { break }
                let result = Result { try self.backend.perform(["--node", name]) }
                DispatchQueue.main.async {
                    guard !self.stopped, self.generation == expected, self.backend.fingerprint() == expected,
                          let index = self.rows.firstIndex(where: { $0.name == name }) else { return }
                    self.rows[index].downloading = false
                    self.rows[index].downloadedAt = Date()
                    if case .success(let data) = result, let speed = data["megabytes_per_second"] as? Double, speed > 0 {
                        self.rows[index].megabytesPerSecond = speed
                    } else { self.rows[index].downloadError = true }
                    self.message = "下载测速 \(position + 1)/\(requested.count) 已完成"
                    self.onChange?()
                }
            }
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                self.downloading = false
                self.rows.indices.forEach { self.rows[$0].downloading = false }
                if self.backend.fingerprint() != expected { self.detect(); return }
                self.message = "下载测速已完成 · 每节点使用 1 MB 样本"
                self.onChange?()
            }
        }
        return true
    }
}
