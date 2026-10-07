import Foundation

// Explicit checks keep this runner effective even when compiled with optimization.
func check(_ condition: Bool) { if !condition { fatalError("runtime regression") } }
let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("amyfree-runtime-test-\(UUID().uuidString)")
defer { try? manager.removeItem(at: root) }
let source = root.appendingPathComponent("source")
let destination = root.appendingPathComponent("user")
try manager.createDirectory(at: source, withIntermediateDirectories: true)
for name in AppRuntime.files { try "fixture \(name)".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let binary = source.appendingPathComponent("mihomo")
try "binary v1".write(to: binary, atomically: true, encoding: .utf8)
check(try AppRuntime.install(resources: source, binary: binary, destination: destination, version: "1"))
let secret = destination.appendingPathComponent(".api-secret")
let firstSecret = try Data(contentsOf: secret)
check(firstSecret.count == 65)
check((try manager.attributesOfItem(atPath: secret.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
check(manager.isExecutableFile(atPath: destination.appendingPathComponent("mihomo").path))
check(!manager.fileExists(atPath: destination.appendingPathComponent(".sub-url").path))
check(!(try AppRuntime.install(resources: source, binary: binary, destination: destination, version: "1")))
let preserved = ["config.yaml", ".sub-url", "providers/nodes.yaml", ".mimio-chain.json", "geoip.dat"]
for name in preserved { try "private fixture \(name)".write(to: destination.appendingPathComponent(name), atomically: true, encoding: .utf8) }
try "binary v2".write(to: binary, atomically: true, encoding: .utf8)
check(try AppRuntime.install(resources: source, binary: binary, destination: destination, version: "2"))
check(try Data(contentsOf: secret) == firstSecret)
for name in preserved { check(try String(contentsOf: destination.appendingPathComponent(name), encoding: .utf8) == "private fixture \(name)") }
check(try String(contentsOf: destination.appendingPathComponent("mihomo"), encoding: .utf8) == "binary v2")
try manager.removeItem(at: destination.appendingPathComponent("proxyctl.sh"))
check(try AppRuntime.install(resources: source, binary: binary, destination: destination, version: "2"))
try manager.removeItem(at: source.appendingPathComponent("country.mmdb"))
do {
    try AppRuntime.install(resources: source, binary: binary, destination: destination, version: "3")
    fatalError("missing bundled file was accepted")
} catch is RuntimeInstallError {}
check(try String(contentsOf: destination.appendingPathComponent(".amyfree-runtime-version"), encoding: .utf8) == "2")
print("PASS fresh install, private permissions, idempotence, upgrade preservation, repair and incomplete-package rejection")
