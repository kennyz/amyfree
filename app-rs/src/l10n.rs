// 界面语言：中文 / English。与 Swift 窗口共用 UserDefaults 的 AmyfreeLanguage，
// 未选择时跟随系统首选语言。文案以 tr("中文", "English") 成对写在调用处。
use objc2_foundation::{ns_string, NSLocale, NSString, NSUserDefaults};

const DEFAULTS_KEY: &str = "AmyfreeLanguage";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Language { Zh, En }

impl Language {
    pub const ALL: [Language; 2] = [Language::Zh, Language::En];

    pub fn current() -> Language {
        let saved = NSUserDefaults::standardUserDefaults().stringForKey(ns_string!("AmyfreeLanguage"));
        match saved.map(|value| value.to_string()).as_deref() {
            Some("zh") => Language::Zh,
            Some("en") => Language::En,
            _ => {
                let preferred = NSLocale::preferredLanguages();
                if preferred.firstObject().is_some_and(|first| first.to_string().starts_with("zh")) { Language::Zh } else { Language::En }
            }
        }
    }

    pub fn save(self) {
        let defaults = NSUserDefaults::standardUserDefaults();
        unsafe { defaults.setObject_forKey(Some(&NSString::from_str(self.code())), &NSString::from_str(DEFAULTS_KEY)) };
    }

    pub fn code(self) -> &'static str { if self == Language::Zh { "zh" } else { "en" } }
    pub fn title(self) -> &'static str { if self == Language::Zh { "中文" } else { "English" } }
}

pub fn tr(zh: &str, en: &str) -> String {
    if Language::current() == Language::Zh { zh.to_string() } else { en.to_string() }
}
