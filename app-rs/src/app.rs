// 菜单栏：状态图标、菜单、定时刷新、网速监控与菜单动作。
// 所有 AppKit 调用都在主线程；网络和系统查询放后台线程，结果经 on_main 回到主线程。
// 注意：弹窗 runModal 会嵌套运行 RunLoop，期间定时器照常触发，因此不要跨弹窗持有 RefCell 借用。
use std::cell::{Cell, OnceCell, RefCell};
use std::path::Path;
use std::ptr::{self, NonNull};
use std::rc::Rc;
use std::thread;
use std::time::{Duration, Instant};

use block2::RcBlock;
use dispatch2::DispatchQueue;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject, NSObjectProtocol, ProtocolObject};
use objc2::{define_class, msg_send, sel, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSAlert, NSAlertFirstButtonReturn, NSAlertSecondButtonReturn, NSAlertThirdButtonReturn, NSApplication,
    NSApplicationActivationPolicy, NSApplicationDelegate, NSBezierPath, NSColor, NSControlStateValueMixed, NSControlStateValueOff,
    NSControlStateValueOn, NSFont, NSFontAttributeName, NSFontWeightRegular, NSImage, NSImageSymbolConfiguration, NSLayoutConstraint,
    NSLineBreakMode, NSMenu, NSMenuDelegate, NSMenuItem, NSStatusBar, NSStatusBarButton, NSStatusItem, NSTextField, NSVariableStatusItemLength,
    NSView, NSWorkspace, NSWorkspaceDidWakeNotification,
};
use objc2_foundation::{
    ns_string, NSArray, NSAttributedString, NSBundle, NSDictionary, NSNotification, NSPoint, NSRect, NSSize, NSString, NSTimer,
    NSUserDefaults,
};

use crate::bridge::{self, LoginState};
use crate::l10n::{tr, Language};
use crate::system::{self, cfg_path, ctl, RunResult};

const CHAIN_EXIT: &str = "MIMIO_CHAIN_EXIT";
const SPEED_MONITOR_KEY: &str = "AmyfreeSpeedMonitor";

// 菜单项 tag → 动作。节点项为 NODE_BASE + 序号，语言项为 LANGUAGE_BASE + 序号。
const TOGGLE_PROXY: isize = 1;
const NODE_MANAGER: isize = 2;
const EDIT_SUBSCRIPTION: isize = 3;
const REFRESH_SUBSCRIPTION: isize = 4;
const SYSTEM_PROXY: isize = 5;
const ROUTING: isize = 6;
const CHAIN: isize = 7;
const TUN: isize = 8;
const LOGIN: isize = 9;
const SPEED_MONITOR: isize = 10;
const NODE_SPEED: isize = 11;
const VERIFY: isize = 12;
const TERMINAL: isize = 13;
const LOG: isize = 14;
const CONFIG_DIR: isize = 15;
const UPGRADE_CENTER: isize = 16;
const ABOUT: isize = 17;
const QUIT: isize = 18;
const DETECT_NODES: isize = 19;
const PICK_AUTO: isize = 20;
const LANGUAGE_BASE: isize = 900;
const NODE_BASE: isize = 10_000;

fn ns(text: &str) -> Retained<NSString> { NSString::from_str(text) }

define_class!(
    /// 应用委托兼菜单动作目标
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "AmyfreeController"]
    pub struct Controller;

    unsafe impl NSObjectProtocol for Controller {}

    unsafe impl NSApplicationDelegate for Controller {
        #[unsafe(method(applicationDidFinishLaunching:))]
        fn did_finish_launching(&self, _notification: &NSNotification) { launch(self.mtm()); }

        #[unsafe(method(applicationWillTerminate:))]
        fn will_terminate(&self, _notification: &NSNotification) {
            bridge::probes_stop();
            let restarting = with_app(|app| app.restarting_for_update.get()).unwrap_or(false);
            if restarting { return; }
            // 兜底：正常退出路径都清理一次
            if system::system_proxy_any_on() { system::run_default("/bin/bash", &[&cfg_path("proxyctl.sh"), "off"]); }
        }

        #[unsafe(method(applicationShouldHandleReopen:hasVisibleWindows:))]
        fn should_handle_reopen(&self, _application: &NSApplication, _visible: bool) -> bool {
            with_app(|app| app.show_routing_rules());
            true
        }
    }

    unsafe impl NSMenuDelegate for Controller {
        #[unsafe(method(menuWillOpen:))]
        fn menu_will_open(&self, _menu: &NSMenu) { with_app(|app| app.refresh()); }
    }

    impl Controller {
        #[unsafe(method(perform:))]
        fn perform(&self, sender: &NSMenuItem) {
            let tag = sender.tag();
            with_app(|app| app.perform(tag));
        }

        #[unsafe(method(didWake:))]
        fn did_wake(&self, _notification: &NSNotification) { bridge::upgrades_automatic_check(); }
    }
);

impl Controller {
    pub fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(());
        unsafe { msg_send![super(this), init] }
    }
}

define_class!(
    /// 菜单栏图标右上角的红点：有可用更新
    #[unsafe(super(NSView, objc2_app_kit::NSResponder, NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "AmyfreeBadgeView"]
    struct BadgeView;

    impl BadgeView {
        #[unsafe(method(drawRect:))]
        fn draw_rect(&self, _dirty: NSRect) {
            NSColor::systemRedColor().setFill();
            NSBezierPath::bezierPathWithOvalInRect(self.bounds()).fill();
        }

        #[unsafe(method(hitTest:))]
        fn hit_test(&self, _point: NSPoint) -> *mut NSView { ptr::null_mut() }
    }
);

impl BadgeView {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(());
        unsafe { msg_send![super(this), initWithFrame: NSRect::ZERO] }
    }
}

thread_local! {
    static APP: OnceCell<Rc<App>> = const { OnceCell::new() };
}

fn with_app<R>(body: impl FnOnce(&App) -> R) -> Option<R> {
    APP.with(|cell| cell.get().cloned()).map(|app| body(&app))
}

/// 后台线程把结果交回主线程
fn on_main(body: impl FnOnce(&App) + Send + 'static) {
    DispatchQueue::main().exec_async(move || { with_app(body); });
}

fn background(work: impl FnOnce() + Send + 'static) { thread::spawn(work); }

#[derive(Clone)]
struct Items {
    running: Retained<NSMenuItem>,
    toggle: Retained<NSMenuItem>,
    node_picker: Retained<NSMenuItem>,
    node_list_label: Retained<NSMenuItem>,
    probe_now: Retained<NSMenuItem>,
    probe_status: Retained<NSMenuItem>,
    chain: Retained<NSMenuItem>,
    upgrade: Retained<NSMenuItem>,
    system_proxy: Retained<NSMenuItem>,
    tun: Retained<NSMenuItem>,
    login: Retained<NSMenuItem>,
    speed: Retained<NSMenuItem>,
    exit_ip: Retained<NSMenuItem>,
}

/// 后台刷新得到的数据
struct Snapshot {
    running: bool,
    exit_ip: Option<String>,
    node: Option<system::CurrentNode>,
    proxy_any: bool,
    provider_nodes: Vec<String>,
}

pub struct App {
    mtm: MainThreadMarker,
    controller: Retained<Controller>,
    status_item: OnceCell<Retained<NSStatusItem>>,
    menu: Retained<NSMenu>,
    nodes_menu: Retained<NSMenu>,
    items: RefCell<Option<Items>>,
    node_names: RefCell<Vec<String>>,
    busy: Cell<bool>,
    glyph_awake: Cell<Option<bool>>,
    node_text: RefCell<Option<String>>,   // 合并到状态行的当前节点，如「LocJP3 (146ms)」
    exit_ip_failures: Cell<u32>,
    cached_node_names: RefCell<Vec<String>>,
    current_node: RefCell<Option<String>>,   // 被固定的节点；自动选择时为 None
    auto_node: RefCell<Option<String>>,      // 自动选择时内核当前选中的最快节点
    speed_timer: RefCell<Option<Retained<NSTimer>>>,
    last_traffic: Cell<Option<(i64, i64, Instant)>>,
    speed_text: RefCell<Option<String>>,     // 菜单栏网速，如「↓1.2M ↑34K」；未开启监控时为 None
    badge: RefCell<Option<Retained<BadgeView>>>,
    last_badge: Cell<Option<bool>>,
    timers: RefCell<Vec<Retained<NSTimer>>>,
    restarting_for_update: Cell<bool>,
}

fn repeating_timer(interval: f64, repeats: bool, body: impl Fn() + 'static) -> Retained<NSTimer> {
    let block = RcBlock::new(move |_timer: NonNull<NSTimer>| body());
    unsafe { NSTimer::scheduledTimerWithTimeInterval_repeats_block(interval, repeats, &block) }
}

fn bundle_string(key: &str) -> Option<String> {
    NSBundle::mainBundle().objectForInfoDictionaryKey(&ns(key))
        .and_then(|value| value.downcast::<NSString>().ok()).map(|value| value.to_string())
}

pub fn speed_monitor_enabled() -> bool { NSUserDefaults::standardUserDefaults().boolForKey(&ns(SPEED_MONITOR_KEY)) }

/// 菜单栏网速文字。数字紧贴箭头、右侧补空格到定长，网速变化时菜单栏图标不左右跳动
pub fn speed_title(down: f64, up: f64) -> String {
    fn format(bytes: f64) -> String {
        let kb = bytes / 1024.0;
        let text = if kb < 1000.0 { format!("{kb:.0}K") } else if kb < 1024.0 * 100.0 { format!("{:.1}M", kb / 1024.0) } else { format!("{:.0}M", kb / 1024.0) };
        format!("{text:<5}")
    }
    format!(" ↓{}↑{}", format(down), format(up))
}

fn probe_icon(indicator: &str, title: &str) -> Option<Retained<NSImage>> {
    let (symbol, color) = match indicator {
        "good" => ("checkmark.circle.fill", NSColor::systemGreenColor()),
        "slow" => ("clock.fill", NSColor::systemYellowColor()),
        "failed" => ("xmark.circle.fill", NSColor::systemRedColor()),
        "testing" => ("arrow.triangle.2.circlepath.circle.fill", NSColor::systemBlueColor()),
        _ => ("questionmark.circle.fill", NSColor::secondaryLabelColor()),
    };
    palette_symbol(symbol, title, &[NSColor::whiteColor(), color])
}

fn palette_symbol(symbol: &str, description: &str, colors: &[Retained<NSColor>]) -> Option<Retained<NSImage>> {
    let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(&ns(symbol), Some(&ns(description)))?;
    let configuration = NSImageSymbolConfiguration::configurationWithPaletteColors(&NSArray::from_retained_slice(colors));
    let image = image.imageWithSymbolConfiguration(&configuration)?;
    image.setTemplate(false);
    Some(image)
}

fn activate(mtm: MainThreadMarker) {
    #[allow(deprecated)]
    NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
}

pub fn show_result(mtm: MainThreadMarker, title: &str, text: &str) {
    let alert = NSAlert::new(mtm);
    alert.setMessageText(&ns(title));
    let chars: Vec<char> = text.chars().collect();
    let tail: String = chars[chars.len().saturating_sub(2500)..].iter().collect();
    alert.setInformativeText(&ns(&tail));
    alert.addButtonWithTitle(&ns(&tr("好", "OK")));
    // 让弹窗浮到最前
    activate(mtm);
    alert.runModal();
}

/// 启动：准备运行组件、建菜单、启动定时器
fn launch(mtm: MainThreadMarker) {
    let application = NSApplication::sharedApplication(mtm);
    application.setActivationPolicy(NSApplicationActivationPolicy::Accessory);   // 不占 Dock

    if let Err(message) = bridge::prepare_runtime() {
        show_result(mtm, &tr("无法准备运行组件", "Could not prepare runtime components"), &message);
        application.terminate(None);
        return;
    }

    let controller = CONTROLLER.with(|cell| cell.get().cloned()).expect("controller");
    let app = Rc::new(App::new(mtm, controller));
    let status_item = NSStatusBar::systemStatusBar().statusItemWithLength(NSVariableStatusItemLength);
    status_item.setMenu(Some(&app.menu));
    let _ = app.status_item.set(status_item);
    APP.with(|cell| { let _ = cell.set(app.clone()); });

    app.set_glyph(false);
    app.set_title(" …");
    app.build_menu();
    bridge::init(probes_changed, upgrades_changed, nodes_saved, routing_saving, restart_for_update);
    bridge::probes_start();
    app.refresh();
    app.timers.borrow_mut().push(repeating_timer(5.0, true, || { with_app(|app| app.refresh()); }));

    let arguments: Vec<String> = std::env::args().collect();
    let has = |flag: &str| arguments.iter().any(|argument| argument == flag);
    if has("--routing-settings") { app.show_routing_rules(); }
    if has("--node-speed") { bridge::show_node_speed(None); }
    if has("--chain-settings") { bridge::show_chain(); }
    if let Some(index) = arguments.iter().position(|argument| argument == "--node-manager") {
        // 可选参数：要选中的节点名（启动时当前节点尚未读取）
        let name = arguments.get(index + 1).filter(|value| !value.starts_with('-'));
        app.open_node_manager(name.map(String::as_str));
    }
    if !Path::new(&cfg_path(".sub-url")).exists() { app.edit_subscription(); }

    app.install_upgrade_badge();
    app.timers.borrow_mut().push(repeating_timer(15.0, false, bridge::upgrades_automatic_check));
    app.timers.borrow_mut().push(repeating_timer(900.0, true, bridge::upgrades_automatic_check));
    unsafe {
        NSWorkspace::sharedWorkspace().notificationCenter().addObserver_selector_name_object(
            &app.controller, sel!(didWake:), Some(NSWorkspaceDidWakeNotification), None);
    }
    if has("--upgrade-center") { bridge::show_upgrade_center(); }
}

thread_local! {
    pub static CONTROLLER: OnceCell<Retained<Controller>> = const { OnceCell::new() };
}

extern "C" fn probes_changed() {
    with_app(|app| {
        app.rebuild_node_list();
        let items = app.items();
        let state = bridge::probes_state();
        items.probe_status.setTitle(&ns(&probe_status_title(&state)));
        items.probe_now.setEnabled(!state.checking && !state.downloading);
        items.chain.setState(if state.chain_enabled { NSControlStateValueOn } else { NSControlStateValueOff });
    });
}

extern "C" fn upgrades_changed() { with_app(|app| app.update_upgrade_badge()); }

extern "C" fn nodes_saved() { with_app(|app| app.refresh()); }

extern "C" fn routing_saving(saving: bool) {
    with_app(|app| { app.busy.set(saving); if !saving { app.refresh(); } });
}

/// 升级助手已接手：停掉定时器，退出时保留系统代理，由新版本接管
extern "C" fn restart_for_update() {
    with_app(|app| {
        app.restarting_for_update.set(true);
        app.timers.borrow_mut().drain(..).for_each(|timer| timer.invalidate());
        if let Some(timer) = app.speed_timer.borrow_mut().take() { timer.invalidate(); }
    });
}

fn probe_status_title(state: &bridge::ProbeState) -> String {
    if state.checking { return tr("节点检测中…", "Testing nodes…"); }
    let minutes = state.interval_minutes;
    tr(&format!("节点自动检测：每 {minutes} 分钟"), &format!("Auto test: every {minutes} min"))
}

impl App {
    pub fn new(mtm: MainThreadMarker, controller: Retained<Controller>) -> App {
        let menu = NSMenu::new(mtm);
        menu.setAutoenablesItems(false);
        menu.setDelegate(Some(ProtocolObject::from_ref(&*controller)));
        let nodes_menu = NSMenu::new(mtm);
        nodes_menu.setAutoenablesItems(false);
        nodes_menu.setDelegate(Some(ProtocolObject::from_ref(&*controller)));
        App {
            mtm, controller, status_item: OnceCell::new(), menu, nodes_menu, items: RefCell::new(None), node_names: RefCell::new(Vec::new()),
            busy: Cell::new(false), glyph_awake: Cell::new(None), node_text: RefCell::new(None), exit_ip_failures: Cell::new(0),
            cached_node_names: RefCell::new(Vec::new()), current_node: RefCell::new(None), auto_node: RefCell::new(None),
            speed_timer: RefCell::new(None), last_traffic: Cell::new(None), speed_text: RefCell::new(None),
            badge: RefCell::new(None), last_badge: Cell::new(None), timers: RefCell::new(Vec::new()), restarting_for_update: Cell::new(false),
        }
    }

    fn items(&self) -> Items { self.items.borrow().clone().expect("menu built") }

    fn button(&self) -> Option<Retained<NSStatusBarButton>> { self.status_item.get().and_then(|item| item.button(self.mtm)) }

    fn set_title(&self, title: &str) {
        if let Some(button) = self.button() { button.setTitle(&ns(title)); }
    }

    // MARK: 菜单骨架

    fn action(&self, title: &str, tag: isize, key: &str) -> Retained<NSMenuItem> {
        let item = unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(self.mtm), &ns(title), Some(sel!(perform:)), &ns(key)) };
        unsafe { item.setTarget(Some(&self.controller)) };
        item.setTag(tag);
        item
    }

    fn label(&self, title: &str) -> Retained<NSMenuItem> {
        let item = unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(self.mtm), &ns(title), None, ns_string!("")) };
        item.setEnabled(false);
        item
    }

    fn submenu(&self, title: &str, items: &[Retained<NSMenuItem>]) -> Retained<NSMenuItem> {
        let child = NSMenu::initWithTitle(NSMenu::alloc(self.mtm), &ns(title));
        child.setAutoenablesItems(false);
        child.setDelegate(Some(ProtocolObject::from_ref(&*self.controller)));
        for item in items { child.addItem(item); }
        let item = unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(self.mtm), &ns(title), None, ns_string!("")) };
        item.setSubmenu(Some(&child));
        item
    }

    fn separator(&self) -> Retained<NSMenuItem> { NSMenuItem::separatorItem(self.mtm) }

    pub fn build_menu(&self) {
        let menu = &self.menu;
        menu.removeAllItems();
        let running = self.label(&tr("Amyfree：检测中…", "Amyfree: checking…"));
        menu.addItem(&running);
        menu.addItem(&self.separator());
        let toggle = self.action(&tr("启用代理", "Enable Proxy"), TOGGLE_PROXY, "t");
        menu.addItem(&toggle);

        let node_picker = unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(self.mtm), &ns(&tr("选择节点", "Select Node")), None, ns_string!("")) };
        node_picker.setSubmenu(Some(&self.nodes_menu));
        menu.addItem(&node_picker);
        let node_list_label = self.label(&tr("订阅节点", "Subscription Nodes"));
        let probe_now = self.action(&tr("立即检测全部节点", "Test All Nodes Now"), DETECT_NODES, "");
        let probe_status = self.label(&probe_status_title(&bridge::probes_state()));
        let upgrade = self.action(&tr("升级中心…", "Upgrade Center…"), UPGRADE_CENTER, "");
        menu.addItem(&self.separator());

        menu.addItem(&self.submenu(&tr("节点与订阅", "Nodes & Subscription"), &[
            self.action(&tr("节点管理…", "Node Management…"), NODE_MANAGER, "e"), self.separator(),
            self.action(&tr("修改订阅地址…", "Edit Subscription URL…"), EDIT_SUBSCRIPTION, "u"),
            self.action(&tr("更新订阅并重启", "Update Subscription & Restart"), REFRESH_SUBSCRIPTION, "r"),
        ]));
        let system_proxy = self.action(&tr("系统代理", "System Proxy"), SYSTEM_PROXY, "s");
        let tun = self.action(&tr("TUN 全局接管", "TUN Mode (All Traffic)"), TUN, "");
        let login = self.action(&tr("开机自启（Amyfree）", "Launch at Login (Amyfree)"), LOGIN, "");
        let speed = self.action(&tr("菜单栏显示网速", "Show Speed in Menu Bar"), SPEED_MONITOR, "");
        speed.setState(if speed_monitor_enabled() { NSControlStateValueOn } else { NSControlStateValueOff });
        let chain = self.action(&tr("链式代理…", "Chain Proxy…"), CHAIN, "");
        let current = Language::current();
        let languages: Vec<_> = Language::ALL.iter().enumerate().map(|(index, language)| {
            let item = self.action(language.title(), LANGUAGE_BASE + index as isize, "");
            item.setState(if *language == current { NSControlStateValueOn } else { NSControlStateValueOff });
            item
        }).collect();
        menu.addItem(&self.submenu(&tr("设置", "Settings"), &[
            system_proxy.clone(), self.action(&tr("分流设置…", "Routing Rules…"), ROUTING, ","),
            chain.clone(), self.separator(), tun.clone(), login.clone(), speed.clone(), self.separator(),
            self.submenu("Languages", &languages),
        ]));
        let exit_ip = self.label(&tr("出口 IP：—", "Exit IP: —"));
        menu.addItem(&self.submenu(&tr("工具", "Tools"), &[
            self.action(&tr("节点测速…", "Node Speed Test…"), NODE_SPEED, "d"), self.separator(),
            exit_ip.clone(), self.action(&tr("验证出口 IP…", "Verify Exit IP…"), VERIFY, "v"), self.separator(),
            self.action(&tr("打开终端（已配代理）", "Open Terminal (Proxy Set)"), TERMINAL, ""),
            self.action(&tr("查看日志", "View Log"), LOG, "l"),
            self.action(&tr("打开配置目录", "Open Config Folder"), CONFIG_DIR, ""), self.separator(),
            upgrade.clone(),
        ]));
        menu.addItem(&self.separator());
        menu.addItem(&self.action(&tr("关于 Amyfree…", "About Amyfree…"), ABOUT, ""));
        menu.addItem(&self.action(&tr("退出 Amyfree", "Quit Amyfree"), QUIT, "q"));
        *self.items.borrow_mut() = Some(Items { running, toggle, node_picker, node_list_label, probe_now, probe_status, chain, upgrade, system_proxy, tun, login, speed, exit_ip });
        self.rebuild_node_list();
    }

    // MARK: 刷新

    pub fn refresh(&self) {
        let items = self.items();
        items.login.setEnabled(!self.busy.get());
        if self.busy.get() { return; }

        let running = system::is_running();
        items.toggle.setTitle(&ns(&if running { tr("关闭代理", "Disable Proxy") } else { tr("启用代理", "Enable Proxy") }));
        self.set_glyph(running);
        self.update_speed_monitor(running);
        if running {
            self.show_running_title();
            self.update_status_line(running);
        } else {
            self.set_title(&tr(" 关闭", " Off"));
            *self.node_text.borrow_mut() = None;
            self.update_status_line(running);
            items.exit_ip.setTitle(&ns(&tr("出口 IP: —", "Exit IP: —")));
        }

        items.tun.setState(if system::tun_enabled() { NSControlStateValueOn } else { NSControlStateValueOff });
        let (state, title) = match bridge::login_state() {
            LoginState::Enabled => (NSControlStateValueOn, tr("开机自启（Amyfree）", "Launch at Login (Amyfree)")),
            LoginState::RequiresApproval => (NSControlStateValueMixed, tr("开机自启（待系统允许）", "Launch at Login (needs approval)")),
            LoginState::Disabled | LoginState::Unavailable => (NSControlStateValueOff, tr("开机自启（Amyfree）", "Launch at Login (Amyfree)")),
        };
        items.login.setState(state);
        items.login.setTitle(&ns(&title));

        // 网络/系统查询放后台，避免卡菜单
        background(|| {
            let running = system::is_running();
            let snapshot = Snapshot {
                running,
                exit_ip: if running { system::fetch_exit_ip() } else { None },
                node: if running { system::fetch_current_node() } else { None },
                // 内核没跑时系统代理不该留着，否则浏览器指向死端口
                proxy_any: system::system_proxy_any_on(),
                provider_nodes: if running { system::provider_node_names() } else { Vec::new() },
            };
            on_main(move |app| app.apply_snapshot(snapshot));
        });
    }

    fn apply_snapshot(&self, snapshot: Snapshot) {
        let items = self.items();
        let Snapshot { running, exit_ip, node, proxy_any, provider_nodes } = snapshot;
        *self.cached_node_names.borrow_mut() = provider_nodes;
        *self.current_node.borrow_mut() = if running { node.as_ref().and_then(|node| node.fixed.clone()) } else { None };
        *self.auto_node.borrow_mut() = node.as_ref().filter(|node| running && node.fixed.is_none()).map(|node| node.name.clone());
        if running {
            match exit_ip {
                Some(ip) => {
                    self.exit_ip_failures.set(0);
                    items.exit_ip.setTitle(&ns(&(tr("出口 IP: ", "Exit IP: ") + &ip)));
                }
                None => {
                    self.exit_ip_failures.set(self.exit_ip_failures.get() + 1);
                    items.exit_ip.setTitle(&ns(&if self.exit_ip_failures.get() >= 2 {
                        tr("出口 IP: 获取失败（节点可能已失效）", "Exit IP: unavailable (node may be down)")
                    } else { tr("出口 IP: 获取中…", "Exit IP: fetching…") }));
                }
            }
            *self.node_text.borrow_mut() = node.map(|node| {
                let probes = bridge::probes_state();
                let measurement = probes.rows.iter().find(|row| row.name == node.name);
                let title = measurement.map(|row| row.title.clone())
                    .unwrap_or_else(|| if node.name == CHAIN_EXIT { tr("链式代理", "Chain proxy") } else { node.name.clone() });
                let delay = measurement.and_then(|row| row.delay).unwrap_or(node.delay);
                let note = if node.name == CHAIN_EXIT { String::new() }
                    else if let Some(fixed) = &node.fixed { if *fixed == node.name { String::new() } else { tr("（所选节点不可用，临时使用）", " (selected node unavailable, using this)") } }
                    else { tr("（自动）", " (auto)") };
                if delay > 0 { format!("{title}{note} ({delay}ms)") } else { format!("{title}{note}") }
            });
        } else {
            items.exit_ip.setTitle(&ns(&tr("出口 IP: —（内核未运行）", "Exit IP: — (core not running)")));
            *self.node_text.borrow_mut() = None;
        }
        self.update_status_line(running);

        let (title, state) = if !running && proxy_any {
            (tr("系统代理: 残留（内核已停）", "System proxy: left on (core stopped)"), NSControlStateValueOn)
        } else if proxy_any {
            (tr("系统代理: 已开启 ✓", "System proxy: on ✓"), NSControlStateValueOn)
        } else {
            (tr("系统代理: 未开启（浏览器不会走代理）", "System proxy: off (browsers bypass proxy)"), NSControlStateValueOff)
        };
        items.system_proxy.setTitle(&ns(&title));
        items.system_proxy.setState(state);
        self.rebuild_node_list();
    }

    /// 自绘猫咪标志（与应用图标同源）：代理开启时睁眼，关闭时闭眼睡觉。模板图随菜单栏深浅色自动着色。
    fn set_glyph(&self, awake: bool) {
        if self.glyph_awake.get() == Some(awake) { return; }
        self.glyph_awake.set(Some(awake));
        let glyph = bridge::cat_glyph(18.0, awake);
        glyph.setTemplate(true);
        glyph.setAccessibilityDescription(Some(&ns(&if awake { tr("Amyfree：代理已开启", "Amyfree: proxy on") } else { tr("Amyfree：代理已关闭", "Amyfree: proxy off") })));
        if let Some(button) = self.button() { button.setImage(Some(&glyph)); }
    }

    /// 运行状态与当前节点合并为一行：「Amyfree：代理已开启 · 节点 (146ms)」
    fn update_status_line(&self, running: bool) {
        let items = self.items();
        if !running { items.running.setTitle(&ns(&tr("Amyfree：代理已关闭", "Amyfree: proxy off"))); return; }
        let node = self.node_text.borrow().as_ref().map(|text| format!(" · {text}")).unwrap_or_default();
        items.running.setTitle(&ns(&(tr("Amyfree：代理已开启", "Amyfree: proxy on") + &node)));
    }

    // MARK: 网速监控

    /// 开关打开且内核运行时每秒采样一次，否则停止并恢复「开启/关闭」文字
    fn update_speed_monitor(&self, running: bool) {
        if speed_monitor_enabled() && running {
            if self.speed_timer.borrow().is_some() { return; }
            *self.speed_text.borrow_mut() = Some(speed_title(0.0, 0.0));
            *self.speed_timer.borrow_mut() = Some(repeating_timer(1.0, true, || { with_app(|app| app.sample_speed()); }));
        } else {
            if let Some(timer) = self.speed_timer.borrow_mut().take() { timer.invalidate(); }
            self.last_traffic.set(None);
            *self.speed_text.borrow_mut() = None;
        }
    }

    /// 内核 /connections 返回累计收发字节，相邻两次之差即为速率
    fn sample_speed(&self) {
        background(|| {
            let Some((down, up)) = system::traffic_totals() else { return };
            let now = Instant::now();
            on_main(move |app| {
                if app.speed_timer.borrow().is_none() { return; }
                let last = app.last_traffic.replace(Some((down, up, now)));
                // 首次采样或内核重启（计数归零）时只记录基线
                let Some((last_down, last_up, at)) = last else { return };
                if down < last_down || up < last_up { return; }
                let elapsed = now.duration_since(at).as_secs_f64().max(0.5);
                *app.speed_text.borrow_mut() = Some(speed_title((down - last_down) as f64 / elapsed, (up - last_up) as f64 / elapsed));
                if !app.busy.get() && system::is_running() { app.show_running_title(); }
            });
        });
    }

    /// 代理开启时的菜单栏文字：开启网速监控则显示网速（等宽字体，避免宽度跳动），否则显示「开启」
    fn show_running_title(&self) {
        let Some(button) = self.button() else { return };
        match self.speed_text.borrow().as_deref() {
            Some(text) => {
                let font = NSFont::monospacedSystemFontOfSize_weight(11.0, unsafe { NSFontWeightRegular });
                let attributes = NSDictionary::from_slices(&[unsafe { NSFontAttributeName }], &[&*font as &AnyObject]);
                let title = unsafe { NSAttributedString::new_with_attributes(&ns(text), &attributes) };
                button.setAttributedTitle(&title);
            }
            None => button.setTitle(&ns(&tr(" 开启", " On"))),
        }
    }

    fn toggle_speed_monitor(&self) {
        NSUserDefaults::standardUserDefaults().setBool_forKey(!speed_monitor_enabled(), &ns(SPEED_MONITOR_KEY));
        self.items().speed.setState(if speed_monitor_enabled() { NSControlStateValueOn } else { NSControlStateValueOff });
        let running = system::is_running();
        self.update_speed_monitor(running);
        if !self.busy.get() && running { self.show_running_title(); }
    }

    /// 节点列表：点击即切换（写入"手动选择"组）
    fn rebuild_node_list(&self) {
        let items = self.items();
        let menu = &self.nodes_menu;
        menu.removeAllItems();
        menu.addItem(&items.node_list_label);
        menu.addItem(&self.separator());
        let state = bridge::probes_state();
        let measurements: Vec<_> = state.rows.iter().filter(|row| row.name != CHAIN_EXIT).collect();
        let names: Vec<String> = if measurements.is_empty() { self.cached_node_names.borrow().clone() } else { measurements.iter().map(|row| row.name.clone()).collect() };
        let count = names.len();
        items.node_list_label.setTitle(&ns(&tr(&format!("订阅节点（{count} 个）"), &format!("Subscription nodes ({count})"))));
        items.node_picker.setTitle(&ns(&tr(&format!("选择节点（{count}）"), &format!("Select Node ({count})"))));
        let auto_node = self.auto_node.borrow().clone();
        let current_node = self.current_node.borrow().clone();
        let chained = auto_node.as_deref() == Some(CHAIN_EXIT) || current_node.as_deref() == Some(CHAIN_EXIT);
        let arrow = auto_node.as_ref().filter(|_| !chained).map(|name| format!(" → {name}")).unwrap_or_default();
        let auto_item = self.action(&(tr("自动选择（最快）", "Auto (fastest)") + &arrow), PICK_AUTO, "");
        auto_item.setState(if auto_node.is_some() && !chained { NSControlStateValueOn } else { NSControlStateValueOff });
        menu.addItem(&auto_item);
        for (index, name) in names.iter().enumerate() {
            let result = measurements.iter().find(|row| row.name == *name);
            let suffix = result.and_then(|row| row.delay).map(|delay| format!("  ·  {delay} ms")).unwrap_or_default();
            let item = self.action(&format!("{name}{suffix}"), NODE_BASE + index as isize, "");
            let indicator = result.map_or("unknown", |row| row.indicator.as_str());
            let indicator_title = result.map_or_else(|| tr("未检测", "Not tested"), |row| row.indicator_title.clone());
            if let Some(icon) = probe_icon(indicator, &indicator_title) { item.setImage(Some(&icon)); }
            let speed = result.map_or_else(|| tr("未测速", "Not measured"), |row| row.speed.clone());
            item.setToolTip(Some(&ns(&format!("{indicator_title}{}{speed}", tr(" · 下载：", " · Download: ")))));
            item.setState(if current_node.as_deref() == Some(name.as_str()) { NSControlStateValueOn } else { NSControlStateValueOff });
            menu.addItem(&item);
        }
        *self.node_names.borrow_mut() = names;
        menu.addItem(&self.separator());
        menu.addItem(&items.probe_now);
        menu.addItem(&items.probe_status);
    }

    // MARK: 动作

    fn perform(&self, tag: isize) {
        match tag {
            TOGGLE_PROXY => self.toggle_proxy(),
            NODE_MANAGER => self.open_node_manager(None),
            EDIT_SUBSCRIPTION => self.edit_subscription(),
            REFRESH_SUBSCRIPTION => self.refresh_subscription(),
            SYSTEM_PROXY => self.toggle_system_proxy(),
            ROUTING => self.show_routing_rules(),
            CHAIN => bridge::show_chain(),
            TUN => self.toggle_tun(),
            LOGIN => self.toggle_login(),
            SPEED_MONITOR => self.toggle_speed_monitor(),
            NODE_SPEED => bridge::show_node_speed(None),
            VERIFY => self.verify(),
            TERMINAL => open_terminal(),
            LOG => self.open_log(),
            CONFIG_DIR => { system::run_default("/usr/bin/open", &[system::cfg_dir()]); }
            UPGRADE_CENTER => bridge::show_upgrade_center(),
            ABOUT => self.show_about(),
            QUIT => self.quit(),
            DETECT_NODES => bridge::probes_detect(),
            PICK_AUTO => self.pick_auto(),
            tag if tag >= NODE_BASE => {
                let name = self.node_names.borrow().get((tag - NODE_BASE) as usize).cloned();
                if let Some(name) = name { self.pick_node(name); }
            }
            tag if tag >= LANGUAGE_BASE => {
                if let Some(language) = Language::ALL.get((tag - LANGUAGE_BASE) as usize) { self.change_language(*language); }
            }
            _ => {}
        }
    }

    fn change_language(&self, language: Language) {
        if language == Language::current() { return; }
        language.save();
        bridge::reset_windows();
        self.build_menu();
        self.last_badge.set(None);
        self.update_upgrade_badge();
        self.glyph_awake.set(None);   // 按新语言重建图标的辅助说明
        probes_changed();
        self.refresh();
    }

    fn open_node_manager(&self, name: Option<&str>) {
        // 默认编辑当前节点：手工固定的节点优先，其次是自动选择当前使用的节点
        let current = name.map(str::to_string).or_else(|| {
            [self.current_node.borrow().clone(), self.auto_node.borrow().clone()].into_iter().flatten().find(|node| node != CHAIN_EXIT)
        });
        bridge::show_node_manager(current.as_deref());
    }

    fn show_routing_rules(&self) {
        if let Err(message) = bridge::show_routing() {
            show_result(self.mtm, &tr("无法打开分流设置", "Could not open routing rules"), &message);
        }
    }

    /// 后台执行耗时操作，期间菜单栏显示进度文字；完成后刷新再回调
    fn busy_task<T: Send + 'static>(&self, title: Option<String>, work: impl FnOnce() -> T + Send + 'static, done: impl FnOnce(&App, T) + Send + 'static) {
        self.busy.set(true);
        if let Some(title) = title { self.set_title(&title); }
        background(move || {
            let result = work();
            on_main(move |app| { app.busy.set(false); app.refresh(); done(app, result); });
        });
    }

    fn pick_node(&self, name: String) {
        if !system::is_running() { bridge::show_node_speed(Some(&name)); return; }
        if bridge::probes_state().chain_enabled { bridge::show_chain(); return; }
        self.busy_task(None, move || {
            // 分流规则走 PROXY（自动测速组），固定它才能让所选节点真正承载流量；手动选择组同步，供"代理 · 手动选择"规则使用
            system::run_default("/bin/bash", &[&ctl(), "use", "PROXY", &name]);
            system::run_default("/bin/bash", &[&ctl(), "use", "手动选择", &name]);
        }, |_, _| {});
    }

    /// 解除 PROXY 组的固定，恢复按延迟自动选择最快节点
    fn pick_auto(&self) {
        if !system::is_running() { return; }
        if bridge::probes_state().chain_enabled { bridge::show_chain(); return; }
        self.busy_task(None, || { system::http_delete("/proxies/PROXY"); }, |_, _| {});
    }

    fn toggle_proxy(&self) {
        let running = system::is_running();
        let title = if running { tr(" 停止中…", " Stopping…") } else { tr(" 启动中…", " Starting…") };
        self.busy_task(Some(title), move || -> Option<(String, String)> {
            let proxyctl = cfg_path("proxyctl.sh");
            if running {
                // 关代理：先把系统代理撤掉，避免浏览器指向一个已停的端口
                system::run_default("/bin/bash", &[&proxyctl, "off"]);
                let mut result = system::run_default("/bin/bash", &[&ctl(), "stop"]);
                // TUN 模式下内核以 root 运行，普通用户无权停止，改为管理员授权停止
                if result.status != 0 { result = system::run_tun_script("stop"); }
                (result.status != 0).then(|| (tr("无法关闭代理", "Could not disable the proxy"), result.out))
            } else {
                // TUN 需要 root 才能建立虚拟网卡，开启时经管理员授权启动
                let result = if system::tun_enabled() { system::run_tun_script("start") } else { system::run_default("/bin/bash", &[&ctl(), "start"]) };
                if result.status != 0 { return Some((tr("无法启用代理", "Could not enable the proxy"), result.out)); }
                // 启动成功后接管系统代理，否则浏览器仍是直连
                let proxy = system::run_default("/bin/bash", &[&proxyctl, "on"]);
                (proxy.status != 0).then(|| (tr("系统代理设置失败", "Could not set system proxy"),
                    tr("代理内核已启动，但系统代理未能开启，浏览器仍会直连。\n\n可尝试手动执行：",
                       "The proxy core started, but the system proxy could not be enabled, so browsers still connect directly.\n\nTry running manually:")
                        + &format!("\n  {proxyctl} on\n\n{}", proxy.out)))
            }
        }, |app, failure| {
            if let Some((title, text)) = failure { show_result(app.mtm, &title, &text); }
        });
    }

    /// 只切换系统代理，不动内核
    fn toggle_system_proxy(&self) {
        let on = system::system_proxy_any_on();
        let title = if on { tr(" 撤销系统代理…", " Clearing system proxy…") } else { tr(" 设置系统代理…", " Setting system proxy…") };
        self.busy_task(Some(title), move || system::run_default("/bin/bash", &[&cfg_path("proxyctl.sh"), if on { "off" } else { "on" }]),
            |app, result: RunResult| if result.status != 0 { show_result(app.mtm, &tr("系统代理操作结果", "System Proxy"), &result.out) });
    }

    fn verify(&self) {
        self.busy_task(Some(tr(" 验证中…", " Verifying…")), || {
            system::run_default("/bin/bash", &[&cfg_path("verify_node.sh"), "7890", system::API, &system::api_secret(), "手动选择"])
        }, |app, result| show_result(app.mtm, &tr("节点验证结果", "Node Verification"), &result.out));
    }

    fn refresh_subscription(&self) {
        self.busy_task(Some(tr(" 更新订阅…", " Updating…")), || system::run("/bin/bash", &[&ctl(), "refresh"], Duration::from_secs(180)),
            |app, result| show_result(app.mtm, &tr("更新订阅", "Update Subscription"), &result.out));
    }

    // MARK: 修改订阅地址

    fn edit_subscription(&self) {
        let alert = NSAlert::new(self.mtm);
        alert.setMessageText(&ns(&tr("修改订阅地址", "Edit Subscription URL")));
        alert.setInformativeText(&ns(&tr("支持 base64 编码的原始链接订阅，也支持 Clash/YAML 格式。\n保存后会自动重新拉取节点并重启代理。",
                                         "Supports base64-encoded link subscriptions and Clash YAML.\nSaving re-fetches the nodes and restarts the proxy.")));
        alert.addButtonWithTitle(&ns(&tr("保存并更新", "Save & Update")));   // 第一个按钮
        alert.addButtonWithTitle(&ns(&tr("仅测试", "Test Only")));          // 第二个按钮
        alert.addButtonWithTitle(&ns(&tr("取消", "Cancel")));               // 第三个按钮

        // 输入框
        let field = NSTextField::initWithFrame(NSTextField::alloc(self.mtm), NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(440.0, 24.0)));
        field.setStringValue(&ns(&system::current_subscription()));
        field.setPlaceholderString(Some(ns_string!("https://example.com/subs/xxxxxxxx")));
        field.setLineBreakMode(NSLineBreakMode::ByTruncatingMiddle);
        alert.setAccessoryView(Some(&field));

        // 让输入框直接获得焦点，省一次点击
        alert.window().setInitialFirstResponder(Some(&field));
        activate(self.mtm);

        let response = alert.runModal();
        let input = field.stringValue().to_string().trim().to_string();
        if response == NSAlertThirdButtonReturn { return; }   // 取消

        // 校验
        if input.is_empty() {
            show_result(self.mtm, &tr("订阅地址为空", "Empty subscription URL"), &tr("没有输入任何内容，未做修改。", "Nothing was entered; no changes made."));
            return;
        }
        if !input.starts_with("http://") && !input.starts_with("https://") {
            show_result(self.mtm, &tr("格式不正确", "Invalid format"), &tr("订阅地址必须以 http:// 或 https:// 开头。", "The subscription URL must start with http:// or https://."));
            return;
        }
        let test_only = response == NSAlertSecondButtonReturn;
        let title = if test_only { tr(" 测试订阅…", " Testing…") } else { tr(" 更新订阅…", " Updating…") };
        self.busy_task(Some(title), move || {
            let result = system::run("/bin/bash", &[&ctl(), if test_only { "test" } else { "sub" }, &input], Duration::from_secs(180));
            let title = if test_only { tr("订阅测试结果", "Subscription Test") }
                else if result.status == 0 { tr("订阅更新成功", "Subscription Updated") } else { tr("订阅更新失败", "Subscription Update Failed") };
            (title, result.out)
        }, |app, (title, text)| show_result(app.mtm, &title, &text));
    }

    fn toggle_tun(&self) {
        let enabling = !system::tun_enabled();
        if enabling {
            let alert = NSAlert::new(self.mtm);
            alert.setMessageText(&ns(&tr("开启 TUN 全局接管需要管理员权限", "TUN mode needs administrator rights")));
            alert.setInformativeText(&ns(&tr("开启后所有 App 的流量都会被接管。系统会弹出密码框。", "All app traffic will go through the proxy. macOS will ask for your password.")));
            alert.addButtonWithTitle(&ns(&tr("继续", "Continue")));
            alert.addButtonWithTitle(&ns(&tr("取消", "Cancel")));
            if alert.runModal() != NSAlertFirstButtonReturn { return; }
        }
        self.busy_task(None, move || system::run_tun_script(if enabling { "on" } else { "off" }),
            |app, result| if result.status != 0 { show_result(app.mtm, &tr("TUN 操作结果", "TUN Mode"), &result.out) });
    }

    fn toggle_login(&self) {
        if self.busy.get() { return; }
        let state = bridge::login_state();
        if state == LoginState::RequiresApproval { self.show_login_approval(); return; }
        let enabling = state != LoginState::Enabled;
        let item = self.items().login;
        self.busy.set(true);
        item.setEnabled(false);
        item.setTitle(&ns(&if enabling { tr("正在开启自启…", "Enabling launch at login…") } else { tr("正在关闭自启…", "Disabling launch at login…") }));
        background(move || {
            let result = bridge::set_login(enabling);
            on_main(move |app| {
                app.busy.set(false);
                app.refresh();
                match result {
                    Ok(LoginState::RequiresApproval) => app.show_login_approval(),
                    Ok(_) => show_result(app.mtm,
                        &if enabling { tr("已开启开机自启", "Launch at login enabled") } else { tr("已关闭开机自启", "Launch at login disabled") },
                        &if enabling { tr("Amyfree 会在你登录 macOS 后自动启动。", "Amyfree will start automatically when you log in to macOS.") }
                         else { tr("Amyfree 不再随登录自动启动，当前应用继续运行。", "Amyfree will no longer start at login; the running app keeps running.") }),
                    Err(message) => show_result(app.mtm, &tr("自启设置失败", "Launch at login failed"), &message),
                }
            });
        });
    }

    fn show_login_approval(&self) {
        let alert = NSAlert::new(self.mtm);
        alert.setMessageText(&ns(&tr("开机自启需要系统允许", "Launch at login needs approval")));
        alert.setInformativeText(&ns(&tr("macOS 已登记 Amyfree，但尚未允许它随登录启动。请在「系统设置 → 通用 → 登录项」中允许 Amyfree。",
                                         "macOS registered Amyfree but hasn't allowed it to start at login. Allow Amyfree in System Settings → General → Login Items.")));
        alert.addButtonWithTitle(&ns(&tr("打开系统设置", "Open System Settings")));
        alert.addButtonWithTitle(&ns(&tr("稍后", "Later")));
        alert.addButtonWithTitle(&ns(&tr("取消自启", "Turn Off")));
        activate(self.mtm);
        let response = alert.runModal();
        if response == NSAlertFirstButtonReturn { bridge::open_login_settings(); }
        else if response == NSAlertThirdButtonReturn {
            match bridge::set_login(false) {
                Ok(_) => self.refresh(),
                Err(message) => show_result(self.mtm, &tr("自启设置失败", "Launch at login failed"), &message),
            }
        }
    }

    fn show_about(&self) {
        let version = bundle_string("CFBundleShortVersionString").unwrap_or_else(|| tr("未知", "unknown"));
        let build = bundle_string("CFBundleVersion").unwrap_or_else(|| tr("未知", "unknown"));
        let app_info = tr(&format!("应用版本：{version}（构建 {build}）"), &format!("App version: {version} (build {build})"));
        // 后台读取内核版本，避免卡住菜单
        background(move || {
            let kernel = system::kernel_version();
            on_main(move |app| {
                let upgrades = bridge::upgrades_state();
                let mut text = app_info + &tr("\n内核版本：", "\nCore version: ") + &kernel;
                if let Some(latest) = &upgrades.app_version {
                    text += &if latest.is_empty() { tr("\n\n🆕 发现新版本，可在升级中心升级。", "\n\n🆕 A new version is available in the Upgrade Center.") }
                        else { tr(&format!("\n\n🆕 发现新版本 {latest}，可在升级中心升级。"), &format!("\n\n🆕 Version {latest} is available in the Upgrade Center.")) };
                } else if upgrades.has_updates {
                    text += &tr("\n\n🆕 规则库有可用更新。", "\n\n🆕 Rule data updates are available.");
                }
                let alert = NSAlert::new(app.mtm);
                alert.setMessageText(&ns(&tr("关于 Amyfree", "About Amyfree")));
                alert.setInformativeText(&ns(&text));
                alert.addButtonWithTitle(&ns(&tr("好", "OK")));
                alert.addButtonWithTitle(&ns(&if upgrades.has_updates { tr("立即升级…", "Upgrade Now…") } else { tr("升级中心…", "Upgrade Center…") }));
                activate(app.mtm);
                if alert.runModal() == NSAlertSecondButtonReturn { bridge::show_upgrade_center(); }
            });
        });
    }

    fn open_log(&self) {
        let log = cfg_path("mihomo.log");
        system::run_default("/usr/bin/open", &["-a", "Console", &log]);
        if !Path::new(&log).exists() {
            show_result(self.mtm, &tr("日志", "Log"), &tr("日志文件尚未生成（服务可能还没启动过）。", "No log file yet (the core may never have started)."));
        }
    }

    fn quit(&self) {
        bridge::probes_stop();
        // 退出前撤掉系统代理，避免浏览器被指向 127.0.0.1:7890 这个死端口。
        // 注意：不动代理内核——退出菜单栏不该顺手把后台代理也关了。
        if system::system_proxy_any_on() { system::run_default("/bin/bash", &[&cfg_path("proxyctl.sh"), "off"]); }
        NSApplication::sharedApplication(self.mtm).terminate(None);
    }

    // MARK: 升级提示

    fn install_upgrade_badge(&self) {
        let Some(button) = self.button() else { return };
        let badge = BadgeView::new(self.mtm);
        badge.setTranslatesAutoresizingMaskIntoConstraints(false);
        button.addSubview(&badge);
        NSLayoutConstraint::activateConstraints(&NSArray::from_retained_slice(&[
            badge.leadingAnchor().constraintEqualToAnchor_constant(&button.leadingAnchor(), 17.0),
            badge.topAnchor().constraintEqualToAnchor_constant(&button.topAnchor(), 2.0),
            badge.widthAnchor().constraintEqualToConstant(6.0),
            badge.heightAnchor().constraintEqualToConstant(6.0),
        ]));
        *self.badge.borrow_mut() = Some(badge);
        self.update_upgrade_badge();
    }

    fn update_upgrade_badge(&self) {
        let available = bridge::upgrades_state().has_updates;
        if self.last_badge.get() == Some(available) { return; }
        self.last_badge.set(Some(available));
        if let Some(badge) = self.badge.borrow().as_ref() { badge.setHidden(!available); }
        let item = self.items().upgrade;
        item.setTitle(&ns(&if available { tr("升级中心 · 有可用更新…", "Upgrade Center · Update Available…") } else { tr("升级中心…", "Upgrade Center…") }));
        let image = if available { palette_symbol("circle.fill", &tr("有可用更新", "Update available"), &[NSColor::systemRedColor()]) } else { None };
        item.setImage(image.as_deref());
        if let Some(button) = self.button() {
            button.setToolTip(Some(&ns(&if available { tr("Amyfree · 有可用更新，打开升级中心", "Amyfree · Update available — open the Upgrade Center") } else { "Amyfree".to_string() })));
        }
    }

    /// 菜单结构（标题与子菜单，不含分隔线），供发布检查使用
    pub fn menu_structure(&self) -> serde_json::Value {
        fn structure(menu: &NSMenu) -> serde_json::Value {
            let items = menu.itemArray();
            serde_json::Value::Array(items.iter().filter(|item| !item.isSeparatorItem()).map(|item| {
                let mut value = serde_json::Map::new();
                if let Some(child) = item.submenu() { value.insert("items".into(), structure(&child)); }
                value.insert("title".into(), item.title().to_string().into());
                serde_json::Value::Object(value)
            }).collect())
        }
        structure(&self.menu)
    }
}

fn open_terminal() {
    let dir = system::cfg_dir();
    let proxy = system::PROXY_URL;
    let script = format!(r#"tell application "Terminal"
    activate
    do script "cd {dir} && export https_proxy={proxy} http_proxy={proxy} all_proxy=socks5://127.0.0.1:7890 no_proxy='localhost,127.0.0.1,::1,*.local,192.168.0.0/16,10.0.0.0/8' && echo '{}' && env | grep -i proxy"
end tell"#, tr("已配置代理环境变量:", "Proxy environment variables set:"));
    background(move || { system::run_default("/usr/bin/osascript", &["-e", &script]); });
}

#[cfg(test)]
mod tests {
    use super::speed_title;

    #[test]
    fn speed_title_is_fixed_width() {
        assert_eq!(speed_title(0.0, 0.0), " ↓0K   ↑0K   ");
        assert_eq!(speed_title(1.1 * 1024.0 * 1024.0, 34.0 * 1024.0), " ↓1.1M ↑34K  ");
        assert_eq!(speed_title(150.0 * 1024.0 * 1024.0, 999.0 * 1024.0), " ↓150M ↑999K ");
    }
}
