import Foundation

struct AppUpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AppVersion: Comparable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard value.range(of: #"\A[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}\z"#, options: .regularExpression) != nil else { return nil }
        parts = value.split(separator: ".").compactMap { Int($0) }
    }
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AvailableUpdate {
    let tag: String
    let notes: String
    var downloadSize: Int64 = 0
    var version: String { String(tag.dropFirst()) }
}

enum UpdateRelease {
    static func parse(_ data: Data, currentVersion: String) throws -> AvailableUpdate? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String, tag.hasPrefix("v"),
              let version = AppVersion(tag), let current = AppVersion(currentVersion),
              let assets = object["assets"] as? [[String: Any]] else {
            throw AppUpdateError(message: tr("无法读取更新信息，请稍后重试。", "Could not read update info. Please try again later."))
        }
        guard version > current else { return nil }
        let expected = ["Amyfree-\(tag.dropFirst())-macOS-arm64.zip", "SHA256SUMS.txt"]
        guard expected.allSatisfy({ name in assets.filter { $0["name"] as? String == name && $0["state"] as? String == "uploaded" }.count == 1 }) else {
            throw AppUpdateError(message: tr("新版安装包尚未准备好，请稍后重试。", "The new package isn't ready yet. Please try again later."))
        }
        let archive = assets.first { $0["name"] as? String == expected[0] }
        return AvailableUpdate(tag: tag, notes: String((object["body"] as? String ?? "").prefix(600)),
                               downloadSize: (archive?["size"] as? NSNumber)?.int64Value ?? 0)
    }

}

struct UpgradeProgress {
    var received: Int64 = 0
    var total: Int64 = 0
    var phase: String = tr("准备下载…", "Preparing download…")
    var fraction: Double? { total > 0 ? min(1, max(0, Double(received) / Double(total))) : nil }
    var text: String {
        guard received > 0 || total > 0 else { return phase }
        let downloaded = String(format: "%.1f MB", Double(received) / 1_000_000)
        if let fraction = fraction {
            return "\(phase) \(Int(fraction * 100))% · \(downloaded) / \(String(format: "%.1f MB", Double(total) / 1_000_000))"
        }
        return phase + tr(" 已下载 ", " downloaded ") + downloaded
    }
    func retainingDownload(from previous: UpgradeProgress?) -> UpgradeProgress {
        guard total == 0 && received == 0 && phase != tr("正在下载…", "Downloading…"), let previous = previous else { return self }
        return UpgradeProgress(received: previous.received, total: previous.total, phase: phase)
    }
}

struct UpgradeSchedule {
    static let interval: TimeInterval = 86400
    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck = lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }
}

enum UpgradeComponent: String, CaseIterable {
    case application, geoip, geosite, mmdb
    var title: String {
        switch self { case .application: return "Amyfree"; case .geoip: return "GeoIP"; case .geosite: return "GeoSite"; case .mmdb: return "MMDB" }
    }
    var file: String? {
        switch self { case .application: return nil; case .geoip: return "geoip.dat"; case .geosite: return "geosite.dat"; case .mmdb: return "country.mmdb" }
    }
    var detail: String {
        switch self { case .application: return tr("应用版本", "App"); case .geoip: return tr("IP 地理分流规则", "GeoIP rules"); case .geosite: return tr("域名分流规则", "GeoSite rules"); case .mmdb: return tr("IP 地理信息数据库", "IP geolocation database") }
    }
}

struct UpgradeRowState {
    var available = false
    var checking = false
    var working = false
    var message = tr("尚未检查", "Not checked yet")
    var progress: UpgradeProgress?
}

enum UpgradeProgressDisplay: Equatable {
    case hidden, determinate(Double)
    init(state: UpgradeRowState, isActive: Bool) {
        guard isActive && state.working else { self = .hidden; return }
        if let fraction = state.progress?.fraction { self = .determinate(fraction) }
        else { self = .hidden }
    }
}
