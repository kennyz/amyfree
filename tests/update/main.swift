import Foundation

var cases = 0
func check(_ condition: Bool) { if !condition { fatalError("update regression") }; cases += 1 }
func rejects(_ body: () throws -> Void) {
    do { try body(); fatalError("invalid release was accepted") } catch { cases += 1 }
}
check(AppVersion("v1.10.0")! > AppVersion("1.9.99")!)
check(AppVersion("1.4.0")! == AppVersion("v1.4.0")!)
for text in ["1.2", "1.2.3-beta", "v1.2.3/path", "1.2.3\n", "1.2.3;open", "999999999999.2.3", ""] {
    check(AppVersion(text) == nil)
}
let release: [String: Any] = ["draft": false, "prerelease": false, "tag_name": "v1.4.0", "body": String(repeating: "x", count: 700),
                             "assets": [["name": "Amyfree-1.4.0-macOS-arm64.zip", "state": "uploaded"], ["name": "SHA256SUMS.txt", "state": "uploaded"]]]
func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
let update = try UpdateRelease.parse(data(release), currentVersion: "1.3.4")
check(update?.version == "1.4.0")
check(update?.notes.count == 600)
check(try UpdateRelease.parse(data(release), currentVersion: "1.4.0") == nil)
check(try UpdateRelease.parse(data(release), currentVersion: "2.0.0") == nil)
for field in ["draft", "prerelease"] {
    var value = release; value[field] = true
    rejects { _ = try UpdateRelease.parse(data(value), currentVersion: "1.3.4") }
}
for tag in ["https://example.com", "v1.4.0\n", "v1.4.0;open", "v1.4.0-beta"] {
    var value = release; value["tag_name"] = tag
    rejects { _ = try UpdateRelease.parse(data(value), currentVersion: "1.3.4") }
}
var missing = release; missing["assets"] = []
rejects { _ = try UpdateRelease.parse(data(missing), currentVersion: "1.3.4") }
var duplicate = release
duplicate["assets"] = (release["assets"] as! [[String: String]]) + [["name": "SHA256SUMS.txt", "state": "uploaded"]]
rejects { _ = try UpdateRelease.parse(data(duplicate), currentVersion: "1.3.4") }
rejects { _ = try UpdateRelease.parse(Data("invalid".utf8), currentVersion: "1.3.4") }
print("PASS \(cases) update checks: version ordering, malformed input, stable releases, assets and release notes")

let now = Date(timeIntervalSince1970: 100_000)
check(UpgradeSchedule.isDue(lastCheck: nil, now: now))
check(!UpgradeSchedule.isDue(lastCheck: now.addingTimeInterval(-86399), now: now))
check(UpgradeSchedule.isDue(lastCheck: now.addingTimeInterval(-86400), now: now))
check(UpgradeSchedule.isDue(lastCheck: now.addingTimeInterval(1), now: now))
let progress = UpgradeProgress(received: 25, total: 100, phase: "下载")
check(progress.fraction == 0.25)
check(progress.text.contains("25%"))
check(UpgradeProgress(received: 200, total: 100).fraction == 1)
check(UpgradeProgress(received: 10, total: 0).fraction == nil)
check(UpgradeComponent.allCases.count == 4)
print("PASS schedule boundaries, clock changes, component mapping and download progress")

check(UpgradeProgressDisplay(state: UpgradeRowState(checking: true), isActive: false) == .hidden)
check(UpgradeProgressDisplay(state: UpgradeRowState(checking: true), isActive: true) == .hidden)
check(UpgradeProgressDisplay(state: UpgradeRowState(working: true), isActive: false) == .hidden)
check(UpgradeProgressDisplay(state: UpgradeRowState(working: true), isActive: true) == .hidden)
check(UpgradeProgress(received: 10, total: 0).text.contains("已下载"))
check(UpgradeProgressDisplay(state: UpgradeRowState(working: true, progress: UpgradeProgress(received: 25, total: 100)), isActive: true) == .determinate(0.25))
print("PASS progress bars are restricted to the actively upgrading component")
let completed = UpgradeProgress(received: 100, total: 100, phase: "正在下载…")
let validating = UpgradeProgress(phase: "正在校验规则格式…").retainingDownload(from: completed)
check(validating.fraction == 1 && validating.received == 100)
check(validating.phase == "正在校验规则格式…")
check(UpgradeProgress(phase: "正在下载…").retainingDownload(from: completed).received == 0)
print("PASS missing size stays static and validation preserves completed byte progress")
