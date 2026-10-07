import Foundation

var failures = 0
func fail(_ message: String = "unexpected callback", file: StaticString = #file, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
func check(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try !value() { fail("expected true", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func checkFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try value() { fail("expected false", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func checkNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #file, line: UInt = #line) {
    do { if try value() != nil { fail("expected nil", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func checkEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
                               file: StaticString = #file, line: UInt = #line) {
    do { let a = try actual(); let e = try expected(); if a != e { fail("\(a) != \(e)", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func throwsError<T>(_ body: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    do { _ = try body(); fail("expected error \(message)", file: file, line: line) } catch {}
}

let fixture = """
mixed-port: 7890
mode: rule
secret: '__API_SECRET__'
dns:
  nameserver: [223.5.5.5]
rules:
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,category-ads-all,REJECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - GEOSITE,geolocation-!cn,PROXY
  - MATCH,PROXY
sniffer:
  enable: true

"""

final class RoutingTests {
    func testRecommendedRoundTrip() throws {
        let document = try RoutingDocument(yaml: fixture)
        check(document.state.chinaDirect)
        check(document.state.blockAds)
        check(document.state.entries.isEmpty)
        let rendered = document.render(document.state)
        checkEqual(try RoutingDocument(yaml: rendered).state, document.state)
        check(rendered.contains("dns:\n  nameserver: [223.5.5.5]"))
        check(rendered.contains("secret: '__API_SECRET__'"))
        check(rendered.contains("sniffer:\n  enable: true"))
    }

    func testPriorityAndFallback() throws {
        let document = try RoutingDocument(yaml: fixture)
        var state = document.state
        state.chinaDirect = false; state.blockAds = false; state.fallback = "DIRECT"
        state.entries.append(RoutingEntry(rule: try UserRule.make(kind: .suffix, input: "https://Example.com/path?q=1", policy: .proxy)))
        let rules = try RoutingDocument(yaml: document.render(state)).ruleTexts
        checkEqual(rules, ["GEOSITE,private,DIRECT", "GEOIP,private,DIRECT,no-resolve", "DOMAIN-SUFFIX,example.com,PROXY", "MATCH,DIRECT"])
        checkFalse(rules.contains { $0.contains("geolocation") })
    }

    func testPreservesAdvancedAndQuotedRules() throws {
        let yaml = fixture.replacingOccurrences(of: "  - MATCH,PROXY", with: "  # user comment\n  - 'AND,((DOMAIN,example.com),(NETWORK,UDP)),DIRECT' # keep\n  - \"DOMAIN,exact.example,REJECT\"\n  - MATCH,PROXY")
        let document = try RoutingDocument(yaml: yaml)
        checkEqual(document.state.entries.count, 2)
        checkNil(document.state.entries[0].userRule)
        checkEqual(document.state.entries[1].userRule?.value, "exact.example")
        let result = document.render(document.state)
        check(result.contains("  - 'AND,((DOMAIN,example.com),(NETWORK,UDP)),DIRECT' # keep"))
        check(result.contains("  # user comment"))
    }

    func testDomainInputAndInjection() throws {
        checkEqual(try UserRule.make(kind: .suffix, input: "*.Example.com", policy: .direct).value, "example.com")
        checkEqual(try UserRule.make(kind: .domain, input: "https://www.example.com:443/a", policy: .reject).value, "www.example.com")
        for input in ["", "example.com,REJECT", "example.com\nMATCH,DIRECT", "https://user:pass@example.com", "-bad.example", "a..com", "8.8.8.8", "https://", "ftp://example.com"] {
            throwsError(try UserRule.make(kind: .suffix, input: input, policy: .direct), input)
        }
    }

    func testIPInput() throws {
        checkEqual(try UserRule.make(kind: .network, input: "8.8.8.8", policy: .direct).value, "8.8.8.8/32")
        checkEqual(try UserRule.make(kind: .network, input: "2001:db8::1", policy: .proxy).value, "2001:db8::1/128")
        checkEqual(try UserRule.make(kind: .network, input: "192.168.1.0/24", policy: .direct).value, "192.168.1.0/24")
        for input in ["300.2.3.4/24", "1.2.3.4/33", "1.2.3.4/", "2001:db8::/129", "1.2.3.4/24/8"] {
            throwsError(try UserRule.make(kind: .network, input: input, policy: .direct))
        }
    }

    func testUnsupportedYAMLAndEarlyMatchAreRejected() {
        for yaml in ["rules: []", "rules:\n  - MATCH,PROXY\n  - DOMAIN,example.com,DIRECT", "rules:\n  - *alias\n  - MATCH,PROXY", "rules:\n  - 'DOMAIN,x,DIRECT\n  - MATCH,PROXY"] {
            throwsError(try RoutingDocument(yaml: yaml))
        }
    }

    func testModeAfterRulesDoesNotDuplicate() throws {
        let yaml = fixture.replacingOccurrences(of: "mode: rule\n", with: "") + "mode: global\n"
        let document = try RoutingDocument(yaml: yaml)
        checkEqual(document.mode, "global")
        let result = document.render(document.state)
        checkEqual(result.components(separatedBy: "mode:").count, 2)
        checkEqual(try RoutingDocument(yaml: result).mode, "rule")
    }

    func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture.write(to: directory.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try "test-secret".write(to: directory.appendingPathComponent(".api-secret"), atomically: true, encoding: .utf8)
        try body(directory)
    }

    func testSaveAndUndoStatePersistWithoutStartingCore() throws {
        try withDirectory { directory in
            var validates = 0
            let store = RoutingStore(directory: directory, validate: { candidate in
                validates += 1
                let runtime = try String(contentsOf: candidate, encoding: .utf8)
                check(runtime.contains("secret: 'test-secret'"))
            }, apply: { _, _ in fail("stopped core must not be reloaded") }, running: { false })
            var draft = try store.load().state
            draft.blockAds = false
            let result = try store.save(draft, expectedSource: fixture)
            checkFalse(result.applied)
            checkEqual(validates, 1)
            checkFalse(try store.load().state.blockAds)
            check(try store.previousState().blockAds)
            checkEqual(try String(contentsOf: store.backupURL, encoding: .utf8), fixture)
            let permission = try FileManager.default.attributesOfItem(atPath: store.configURL.path)[.posixPermissions] as? Int
            checkEqual(permission, 0o600)
            checkFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".mimio-validate-") })
        }
    }

    func testValidationFailureLeavesAllFilesUntouched() throws {
        try withDirectory { directory in
            let store = RoutingStore(directory: directory, validate: { _ in throw RoutingError("invalid config") },
                                     apply: { _, _ in fail() }, running: { true })
            var draft = try store.load().state; draft.blockAds = false
            throwsError(try store.save(draft, expectedSource: fixture))
            checkEqual(try String(contentsOf: store.configURL, encoding: .utf8), fixture)
            checkFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
            checkFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".run-config.yaml").path))
        }
    }

    func testReloadFailureRestoresConfigRuntimeAndTunBackup() throws {
        try withDirectory { directory in
            let runtime = directory.appendingPathComponent(".run-config.yaml")
            let notun = directory.appendingPathComponent(".config.yaml.notun")
            try "original runtime".write(to: runtime, atomically: true, encoding: .utf8)
            try fixture.write(to: notun, atomically: true, encoding: .utf8)
            var reloads = 0
            let store = RoutingStore(directory: directory, validate: { _ in }, apply: { path, state in
                reloads += 1
                if reloads == 1 {
                    checkFalse(state.blockAds)
                    throw RoutingError("rejected by core")
                }
                checkEqual(try String(contentsOf: path, encoding: .utf8), "original runtime")
                check(state.blockAds)
            }, running: { true })
            var draft = try store.load().state; draft.blockAds = false
            throwsError(try store.save(draft, expectedSource: fixture))
            checkEqual(reloads, 2)
            checkEqual(try String(contentsOf: store.configURL, encoding: .utf8), fixture)
            checkEqual(try String(contentsOf: runtime, encoding: .utf8), "original runtime")
            checkEqual(try String(contentsOf: notun, encoding: .utf8), fixture)
        }
    }

    func testStaleSaveAndConcurrentValidationAreRejected() throws {
        try withDirectory { directory in
            let concurrent = fixture + "# external change\n"
            let store = RoutingStore(directory: directory, validate: { _ in
                try concurrent.write(to: directory.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
            }, apply: { _, _ in fail() }, running: { false })
            let draft = try store.load().state
            throwsError(try store.save(draft, expectedSource: "outdated"))
            throwsError(try store.save(draft, expectedSource: fixture))
            checkEqual(try String(contentsOf: store.configURL, encoding: .utf8), concurrent)
        }
    }

    func testTunBackupUpdatedWithoutCopyingTunBlock() throws {
        try withDirectory { directory in
            let notun = directory.appendingPathComponent(".config.yaml.notun")
            try fixture.write(to: notun, atomically: true, encoding: .utf8)
            let current = fixture + "tun:\n  enable: true\n"
            try current.write(to: directory.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
            let store = RoutingStore(directory: directory, validate: { _ in }, apply: { _, _ in }, running: { false })
            var draft = try store.load().state; draft.chinaDirect = false
            try store.save(draft, expectedSource: current)
            let backup = try String(contentsOf: notun, encoding: .utf8)
            checkFalse(backup.contains("tun:"))
            checkFalse(try RoutingDocument(yaml: backup).state.chinaDirect)
            check(try String(contentsOf: store.configURL, encoding: .utf8).contains("tun:\n  enable: true"))
        }
    }
}

let tests = RoutingTests()
let cases: [(String, () throws -> Void)] = [
    ("recommended round trip", tests.testRecommendedRoundTrip),
    ("priority and fallback", tests.testPriorityAndFallback),
    ("advanced and quoted preservation", tests.testPreservesAdvancedAndQuotedRules),
    ("domain normalization and injection", tests.testDomainInputAndInjection),
    ("IPv4 / IPv6 validation", tests.testIPInput),
    ("unsupported YAML and early MATCH", tests.testUnsupportedYAMLAndEarlyMatchAreRejected),
    ("mode after rules", tests.testModeAfterRulesDoesNotDuplicate),
    ("save / backup / read back", tests.testSaveAndUndoStatePersistWithoutStartingCore),
    ("validation failure leaves files unchanged", tests.testValidationFailureLeavesAllFilesUntouched),
    ("reload failure rolls back all files", tests.testReloadFailureRestoresConfigRuntimeAndTunBackup),
    ("stale / concurrent edit rejected", tests.testStaleSaveAndConcurrentValidationAreRejected),
    ("TUN-off backup retains routing", tests.testTunBackupUpdatedWithoutCopyingTunBlock)
]
for (name, test) in cases {
    let before = failures
    do { try test() } catch { fail("\(name): \(error.localizedDescription)") }
    if failures == before { print("PASS \(name)") }
}
print("\(cases.count) cases, \(failures) failures")
exit(failures == 0 ? 0 : 1)
