// ============================================================
//  Amyfree 菜单栏 App：AppKit 经 objc2 调用。
//  尚未迁移的窗口在 app/*.swift，编译成静态库链接进来（见 build.rs、bridge.rs）。
//  编译: bash scripts/build-app.sh
// ============================================================
mod app;
mod bridge;
mod l10n;
mod system;

use std::process::exit;

use objc2::runtime::ProtocolObject;
use objc2::MainThreadMarker;
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy};

use crate::app::{App, Controller, CONTROLLER};
use crate::l10n::tr;

fn main() {
    let mtm = MainThreadMarker::new().expect("main thread");
    let arguments: Vec<String> = std::env::args().collect();
    let has = |flag: &str| arguments.iter().any(|argument| argument == flag);

    // 只渲染升级中心为 PNG 的诊断入口：不读用户设置、不安装运行组件、不联网。
    if let Some(index) = arguments.iter().position(|argument| argument == "--render-upgrade-center") {
        let Some(path) = arguments.get(index + 1) else { exit(2) };
        NSApplication::sharedApplication(mtm).setActivationPolicy(NSApplicationActivationPolicy::Prohibited);
        exit(if bridge::render_upgrade_center(path, has("--preview-progress"), has("--preview-application")) { 0 } else { 1 });
    }

    if has("--prepare-runtime") {
        let result = bridge::prepare_runtime().and_then(|updated| {
            let ctl = std::fs::metadata(system::ctl()).is_ok_and(|meta| { use std::os::unix::fs::PermissionsExt; meta.permissions().mode() & 0o111 != 0 });
            if updated || ctl { Ok(()) } else { Err(tr("此构建未包含运行组件。", "This build does not include runtime components.")) }
        });
        match result {
            Ok(()) => { println!("{}", tr("运行组件已就绪", "Runtime components ready")); exit(0) }
            Err(message) => { eprintln!("{message}"); exit(1) }
        }
    }

    // 诊断命令使用与菜单完全相同的系统接口，便于核验登记状态。
    if let Some(option) = arguments.get(1).filter(|option| ["--login-status", "--enable-login", "--disable-login"].contains(&option.as_str())) {
        if option != "--login-status" {
            if let Err(message) = bridge::set_login(option == "--enable-login") { eprintln!("{message}"); exit(1) }
        }
        let state = bridge::login_state();
        println!("{}", state.raw());
        exit(if state == bridge::LoginState::RequiresApproval { 2 } else { 0 });
    }

    if has("--menu-structure") {
        let _ = NSApplication::sharedApplication(mtm);
        let inspector = App::new(mtm, Controller::new(mtm));
        inspector.build_menu();
        println!("{}", inspector.menu_structure());
        exit(0);
    }

    let application = NSApplication::sharedApplication(mtm);
    let controller = Controller::new(mtm);
    application.setDelegate(Some(ProtocolObject::from_ref(&*controller)));
    CONTROLLER.with(|cell| { let _ = cell.set(controller); });
    application.run();
}
