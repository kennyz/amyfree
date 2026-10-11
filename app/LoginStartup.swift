import Foundation
import ServiceManagement

enum LoginStartupState: String {
    case disabled, enabled, requiresApproval, unavailable
}

protocol LoginRegistration {
    var state: LoginStartupState { get }
    func register() throws
    func unregister() throws
}

private final class NativeLoginRegistration: LoginRegistration {
    private let service = SMAppService.mainApp
    var state: LoginStartupState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

struct LoginStartupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LoginStartupController {
    private let registration: LoginRegistration
    var state: LoginStartupState { registration.state }
    init(registration: LoginRegistration) { self.registration = registration }
    convenience init() { self.init(registration: NativeLoginRegistration()) }

    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> LoginStartupState {
        if enabled, state == .enabled || state == .requiresApproval { return state }
        if !enabled, state == .disabled { return .disabled }
        do {
            if enabled { try registration.register() }
            else { try registration.unregister() }
        } catch {
            // 已登记/尚待允许时，系统可能返回错误；以读回状态为准。
            if enabled, state == .enabled || state == .requiresApproval { return state }
            if !enabled, state == .disabled { return .disabled }
            throw LoginStartupError(message: (enabled ? tr("macOS 未能开启 Amyfree 的登录自启。", "macOS could not enable launch at login for Amyfree.") : tr("macOS 未能关闭 Amyfree 的登录自启。", "macOS could not disable launch at login for Amyfree.")) + "\n" + error.localizedDescription)
        }
        let actual = state
        guard enabled ? [.enabled, .requiresApproval].contains(actual) : actual == .disabled else {
            throw LoginStartupError(message: tr("系统尚未确认自启设置，请从已安装的 Amyfree.app 重试，或检查「系统设置 → 通用 → 登录项」。", "macOS hasn't confirmed the login setting. Retry from the installed Amyfree.app, or check System Settings → General → Login Items."))
        }
        return actual
    }
}
