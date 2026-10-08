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
    var version: String { String(tag.dropFirst()) }
}

enum UpdateRelease {
    static func parse(_ data: Data, currentVersion: String) throws -> AvailableUpdate? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String, tag.hasPrefix("v"),
              let version = AppVersion(tag), let current = AppVersion(currentVersion),
              let assets = object["assets"] as? [[String: Any]] else {
            throw AppUpdateError(message: "无法读取更新信息，请稍后重试。")
        }
        guard version > current else { return nil }
        let expected = ["Amyfree-\(tag.dropFirst())-macOS-arm64.zip", "SHA256SUMS.txt"]
        guard expected.allSatisfy({ name in assets.filter { $0["name"] as? String == name && $0["state"] as? String == "uploaded" }.count == 1 }) else {
            throw AppUpdateError(message: "新版安装包尚未准备好，请稍后重试。")
        }
        return AvailableUpdate(tag: tag, notes: String((object["body"] as? String ?? "").prefix(600)))
    }

}
