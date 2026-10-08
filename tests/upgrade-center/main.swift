import Foundation

func check(_ condition: Bool) { if !condition { fatalError("upgrade-center regression") } }
let suite = "AmyfreeUpgradeTests.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
var checks = 0
let files: [String: Any] = ["geoip.dat": ["available": true], "geosite.dat": ["available": false], "country.mmdb": ["available": true]]
let coordinator = UpgradeCoordinator(directory: "/not-used", defaults: preferences, applicationCheck: {
    checks += 1
    return AvailableUpdate(tag: "v99.0.0", notes: "fixture", downloadSize: 100)
}, geodataCheck: { files })
func waitForCheck(_ coordinator: UpgradeCoordinator) {
    let deadline = Date().addingTimeInterval(5)
    while coordinator.checking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!coordinator.checking)
}
coordinator.automaticCheck(); coordinator.automaticCheck()
waitForCheck(coordinator)
check(checks == 1)
check(coordinator.hasUpdates)
check(coordinator.rows[.geoip]?.available == true)
check(coordinator.rows[.geosite]?.available == false)
check(coordinator.lastCheck != nil)
coordinator.automaticCheck()
check(checks == 1)
let restored = UpgradeCoordinator(directory: "/not-used", defaults: preferences)
check(restored.hasUpdates)
check(restored.rows[.application]?.available == true)
check(restored.rows[.mmdb]?.available == true)
check(restored.rows[.geosite]?.available == false)
preferences.set(Date().addingTimeInterval(-86401), forKey: "AmyfreeUpgrade.lastAttempt")
coordinator.automaticCheck(); waitForCheck(coordinator)
check(checks == 2)
preferences.set("v0.0.0", forKey: "AmyfreeUpgrade.availableTag")
let installed = UpgradeCoordinator(directory: "/not-used", defaults: preferences)
check(installed.rows[.application]?.available == false)
check(installed.rows[.application]?.message == "当前版本已更新")
check(installed.rows[.geoip]?.available == true)
let offline = UpgradeCoordinator(directory: "/not-used", defaults: preferences, applicationCheck: {
    throw AppUpdateError(message: "offline")
}, geodataCheck: { throw AppUpdateError(message: "offline") })
offline.check(); waitForCheck(offline)
check(offline.rows[.geoip]?.available == true)
check(offline.rows[.geoip]?.message == "offline")
let events = UpgradeCoordinator.events("{\"event\":\"progress\",\"downloaded\":10,\"total\":20}\nnot-json\n{\"event\":\"complete\"}\n")
check(events.count == 2)
check(events.first?["downloaded"] as? Int == 10)
print("PASS daily checks across launches, concurrent-check guard, persistent per-component badges, post-upgrade clearing and offline reminder retention")
