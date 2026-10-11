import Foundation

// 界面语言：中文 / English。选择保存在 UserDefaults，未选择时跟随系统首选语言。
// 文案以 tr("中文", "English") 成对写在调用处，无需 .lproj 资源，切换后立即生效。
enum AppLanguage: String, CaseIterable {
    case zh, en

    static let defaultsKey = "AmyfreeLanguage"

    static var current: AppLanguage {
        get {
            if let saved = UserDefaults.standard.string(forKey: defaultsKey), let value = AppLanguage(rawValue: saved) { return value }
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String { self == .zh ? "中文" : "English" }
}

func tr(_ zh: String, _ en: String) -> String { AppLanguage.current == .zh ? zh : en }
