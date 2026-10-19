// 尚未迁移到 Rust 的 Swift 窗口（app/Bridge.swift）的 C 接口与安全封装。
// 每迁移一个窗口，就删掉这里和 Bridge.swift 中对应的入口。
use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;

use objc2::rc::Retained;
use objc2_app_kit::NSImage;
use serde_json::Value;

pub type Callback = extern "C" fn();
pub type FlagCallback = extern "C" fn(bool);

unsafe extern "C" {
    fn amy_free(pointer: *mut c_char);
    fn amy_ui_init(probes_changed: Callback, upgrades_changed: Callback, nodes_saved: Callback,
                   routing_saving: FlagCallback, restart_for_update: Callback);
    fn amy_runtime_prepare(message: *mut *mut c_char) -> i32;
    fn amy_login_state() -> *mut c_char;
    fn amy_login_set(enabled: bool, message: *mut *mut c_char) -> *mut c_char;
    fn amy_login_open_settings();
    fn amy_cat_glyph(size: f64, awake: bool) -> *mut c_void;
    fn amy_probes_start();
    fn amy_probes_stop();
    fn amy_probes_detect();
    fn amy_probes_state() -> *mut c_char;
    fn amy_upgrades_automatic_check();
    fn amy_upgrades_state() -> *mut c_char;
    fn amy_render_upgrade_center(path: *const c_char, progress: bool, application: bool) -> i32;
    fn amy_show_node_speed(select: *const c_char);
    fn amy_show_node_manager(select: *const c_char);
    fn amy_show_chain();
    fn amy_show_routing() -> *mut c_char;
    fn amy_show_upgrade_center();
    fn amy_reset_windows();
}

/// 接管 Swift 分配的字符串（空指针为 None）。
fn take(pointer: *mut c_char) -> Option<String> {
    if pointer.is_null() { return None; }
    let text = unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned();
    unsafe { amy_free(pointer) };
    Some(text)
}

fn take_json(pointer: *mut c_char) -> Value {
    take(pointer).and_then(|text| serde_json::from_str(&text).ok()).unwrap_or(Value::Null)
}

fn with_optional<R>(text: Option<&str>, call: impl FnOnce(*const c_char) -> R) -> R {
    let owned = text.and_then(|value| CString::new(value).ok());
    call(owned.as_ref().map_or(ptr::null(), |value| value.as_ptr()))
}

pub fn init(probes_changed: Callback, upgrades_changed: Callback, nodes_saved: Callback, routing_saving: FlagCallback, restart_for_update: Callback) {
    unsafe { amy_ui_init(probes_changed, upgrades_changed, nodes_saved, routing_saving, restart_for_update) }
}

/// Ok(true) 表示已安装或更新了运行组件。
pub fn prepare_runtime() -> Result<bool, String> {
    let mut message = ptr::null_mut();
    match unsafe { amy_runtime_prepare(&mut message) } {
        -1 => Err(take(message).unwrap_or_default()),
        status => Ok(status == 1),
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LoginState { Disabled, Enabled, RequiresApproval, Unavailable }

impl LoginState {
    fn parse(text: &str) -> LoginState {
        match text {
            "enabled" => LoginState::Enabled,
            "requiresApproval" => LoginState::RequiresApproval,
            "disabled" => LoginState::Disabled,
            _ => LoginState::Unavailable,
        }
    }
    pub fn raw(self) -> &'static str {
        match self {
            LoginState::Disabled => "disabled",
            LoginState::Enabled => "enabled",
            LoginState::RequiresApproval => "requiresApproval",
            LoginState::Unavailable => "unavailable",
        }
    }
}

pub fn login_state() -> LoginState { LoginState::parse(&take(unsafe { amy_login_state() }).unwrap_or_default()) }

/// 可在后台线程调用。
pub fn set_login(enabled: bool) -> Result<LoginState, String> {
    let mut message = ptr::null_mut();
    match take(unsafe { amy_login_set(enabled, &mut message) }) {
        Some(state) => Ok(LoginState::parse(&state)),
        None => Err(take(message).unwrap_or_default()),
    }
}

pub fn open_login_settings() { unsafe { amy_login_open_settings() } }

pub fn cat_glyph(size: f64, awake: bool) -> Retained<NSImage> {
    unsafe { Retained::from_raw(amy_cat_glyph(size, awake).cast::<NSImage>()) }.expect("cat glyph")
}

pub fn probes_start() { unsafe { amy_probes_start() } }
pub fn probes_stop() { unsafe { amy_probes_stop() } }
pub fn probes_detect() { unsafe { amy_probes_detect() } }

pub struct ProbeRow {
    pub name: String,
    pub title: String,
    pub indicator: String,
    pub indicator_title: String,
    pub speed: String,
    pub delay: Option<i64>,
}

pub struct ProbeState {
    pub rows: Vec<ProbeRow>,
    pub checking: bool,
    pub downloading: bool,
    pub chain_enabled: bool,
    pub interval_minutes: i64,
}

pub fn probes_state() -> ProbeState {
    let value = take_json(unsafe { amy_probes_state() });
    let text = |row: &Value, key: &str| row[key].as_str().unwrap_or_default().to_string();
    ProbeState {
        rows: value["rows"].as_array().map(|rows| rows.iter().map(|row| ProbeRow {
            name: text(row, "name"), title: text(row, "title"), indicator: text(row, "indicator"),
            indicator_title: text(row, "indicator_title"), speed: text(row, "speed"), delay: row["delay"].as_i64(),
        }).collect()).unwrap_or_default(),
        checking: value["checking"].as_bool().unwrap_or(false),
        downloading: value["downloading"].as_bool().unwrap_or(false),
        chain_enabled: value["chain_enabled"].as_bool().unwrap_or(false),
        interval_minutes: value["interval_minutes"].as_i64().unwrap_or(3),
    }
}

pub fn upgrades_automatic_check() { unsafe { amy_upgrades_automatic_check() } }

pub struct UpgradeState {
    pub has_updates: bool,
    /// 有新版应用时为 Some（版本号可能为空字符串）
    pub app_version: Option<String>,
}

pub fn upgrades_state() -> UpgradeState {
    let value = take_json(unsafe { amy_upgrades_state() });
    UpgradeState { has_updates: value["has_updates"].as_bool().unwrap_or(false), app_version: value["app_version"].as_str().map(str::to_string) }
}

pub fn render_upgrade_center(path: &str, progress: bool, application: bool) -> bool {
    let path = CString::new(path).expect("path");
    unsafe { amy_render_upgrade_center(path.as_ptr(), progress, application) == 0 }
}

pub fn show_node_speed(select: Option<&str>) { with_optional(select, |pointer| unsafe { amy_show_node_speed(pointer) }) }
pub fn show_node_manager(select: Option<&str>) { with_optional(select, |pointer| unsafe { amy_show_node_manager(pointer) }) }
pub fn show_chain() { unsafe { amy_show_chain() } }
pub fn show_routing() -> Result<(), String> { take(unsafe { amy_show_routing() }).map_or(Ok(()), Err) }
pub fn show_upgrade_center() { unsafe { amy_show_upgrade_center() } }
pub fn reset_windows() { unsafe { amy_reset_windows() } }
