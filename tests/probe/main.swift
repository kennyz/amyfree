import Foundation

final class FakeProbeBackend: NodeProbeBackend {
    private let lock = NSLock()
    var token = "first"
    var calls = 0
    var cancelled = false
    let entered = DispatchSemaphore(value: 0)
    func fingerprint() -> String { lock.lock(); defer { lock.unlock() }; return token }
    func perform(_ args: [String]) throws -> [String: Any] {
        lock.lock(); let stamp = token; calls += 1; lock.unlock()
        entered.signal()
        Thread.sleep(forTimeInterval: 0.04)
        if args.first == "--node" { return ["ok": true, "megabytes_per_second": 2.0] }
        return ["fingerprint": stamp, "names": ["a", "b", "c"], "certificates": [
            "a": ["state": "valid", "days_left": 90, "not_after": 2_000_000_000.0],
            "b": ["state": "expiring", "days_left": 10], "c": ["state": "unknown"]], "results": [
            ["name": "a", "delay": 50], ["name": "b", "delay": 900], ["name": "c", "delay": 0]]]
    }
    func changeToken() { lock.lock(); token = "changed"; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
var failures = 0
func expect(_ value: Bool, _ note: String) { if !value { failures += 1; print("FAIL \(note)") } }
func pump(_ condition: () -> Bool) {
    let until = Date().addingTimeInterval(3)
    while !condition() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    expect(condition(), "asynchronous operation completed")
}
expect(NodeProbeCoordinator.interval == 30, "30 second interval")
expect(NodeIndicator.quality(delay: 80) == .good, "fast state")
expect(NodeIndicator.quality(delay: 900) == .slow, "slow state")
expect(NodeIndicator.quality(delay: 0) == .failed, "failed state")
expect(NodeCertificate(["state":"valid","days_left":90]).text == "剩余 90 天", "certificate remaining days")
expect(NodeCertificate(["state":"expired"]).indicator == .failed, "expired certificate icon")
expect(NodeCertificate(["state":"expiring","days_left":10]).indicator == .slow, "expiring certificate icon")
expect(NodeCertificate(["state":"unknown"]).text == "无法确认", "unknown certificate is not expired")
do {
    let backend = FakeProbeBackend(); let model = NodeProbeCoordinator(backend: backend)
    expect(model.detect(), "manual check starts")
    expect(!model.detect(), "overlapping checks rejected")
    pump { !model.checking }
    expect(model.rows.map(\.indicator) == [.good, .slow, .failed], "results classified")
    expect(model.rows[0].certificate.text == "剩余 90 天", "certificate results reach table model")
    expect(model.rows[0].certificate.expires != nil, "certificate expiry date decoded")
    expect(model.download(names: ["a"]), "manual download starts")
    expect(!model.detect(), "auto latency waits for download")
    pump { !model.downloading }
    expect(model.rows[0].speedText == "2.00 MB/s", "actual speed unit")
    model.stop(); expect(backend.cancelled, "stop cancels backend")
}
do {
    let backend = FakeProbeBackend(); let model = NodeProbeCoordinator(backend: backend)
    model.detect(); _ = backend.entered.wait(timeout: .now() + 1); backend.changeToken()
    pump { !model.checking && model.roundCount >= 2 }
    expect(model.rows.count == 3, "catalogue reloaded after stale result discarded")
    model.stop()
}
do {
    let backend = FakeProbeBackend(); let model = NodeProbeCoordinator(backend: backend)
    model.start(); model.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    expect(model.rows.isEmpty && model.roundCount == 0, "cancelled result does not update state")
}
print("Node probe tests: \(failures) failures")
exit(failures == 0 ? 0 : 1)
