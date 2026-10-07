import Foundation

final class FakeRegistration: LoginRegistration {
    var state: LoginStartupState = .disabled
    var registerCalls = 0
    var unregisterCalls = 0
    var afterRegister: LoginStartupState = .enabled
    var registerFailure = false
    var unregisterFailure = false
    func register() throws {
        registerCalls += 1
        if registerFailure { throw LoginStartupError(message: "registration rejected") }
        state = afterRegister
    }
    func unregister() throws {
        unregisterCalls += 1
        if unregisterFailure { throw LoginStartupError(message: "unregister rejected") }
        state = .disabled
    }
}

func expect(_ condition: @autoclosure () throws -> Bool) throws {
    if try !condition() { throw LoginStartupError(message: "assertion failed") }
}
func expectFailure(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw LoginStartupError(message: "expected failure was swallowed")
}

let cases: [(String, () throws -> Void)] = [
    ("register without kernel or plist", {
        let fake = FakeRegistration()
        let controller = LoginStartupController(registration: fake)
        try expect(controller.setEnabled(true) == .enabled)
        try expect(fake.registerCalls == 1)
    }),
    ("disable and read back", {
        let fake = FakeRegistration(); fake.state = .enabled
        let controller = LoginStartupController(registration: fake)
        try expect(controller.setEnabled(false) == .disabled)
        try expect(fake.unregisterCalls == 1)
    }),
    ("pending approval is not reported as enabled", {
        let fake = FakeRegistration(); fake.afterRegister = .requiresApproval
        let controller = LoginStartupController(registration: fake)
        try expect(controller.setEnabled(true) == .requiresApproval)
        try expect(controller.state != .enabled)
    }),
    ("register error is surfaced and remains disabled", {
        let fake = FakeRegistration(); fake.registerFailure = true
        let controller = LoginStartupController(registration: fake)
        try expectFailure { try controller.setEnabled(true) }
        try expect(controller.state == .disabled)
    }),
    ("unregister error is surfaced and remains enabled", {
        let fake = FakeRegistration(); fake.state = .enabled; fake.unregisterFailure = true
        let controller = LoginStartupController(registration: fake)
        try expectFailure { try controller.setEnabled(false) }
        try expect(controller.state == .enabled)
    }),
    ("successful call with wrong readback is rejected", {
        let fake = FakeRegistration(); fake.afterRegister = .disabled
        let controller = LoginStartupController(registration: fake)
        try expectFailure { try controller.setEnabled(true) }
    }),
    ("repeated enable is idempotent", {
        let fake = FakeRegistration(); fake.state = .enabled
        let controller = LoginStartupController(registration: fake)
        try expect(controller.setEnabled(true) == .enabled)
        try expect(fake.registerCalls == 0)
    }),
    ("pending approval can be cancelled", {
        let fake = FakeRegistration(); fake.state = .requiresApproval
        let controller = LoginStartupController(registration: fake)
        try expect(controller.setEnabled(false) == .disabled)
        try expect(fake.unregisterCalls == 1)
    })
]
var failures = 0
for (name, test) in cases {
    do { try test(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
}
print("\(cases.count) cases, \(failures) failures")
exit(failures == 0 ? 0 : 1)
