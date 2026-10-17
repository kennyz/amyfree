// 路径、外部命令与本地内核 API。均为阻塞调用，放后台线程执行。
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::l10n::{tr, Language};

pub const API: &str = "127.0.0.1:9090";
pub const PROXY_URL: &str = "http://127.0.0.1:7890";

/// 开发时可用 MIHOMO_HOME 指向仓库里的目录，避免去动 ~/.config：
///   MIHOMO_HOME=/path/to/repo/mihomo Amyfree.app/Contents/MacOS/Amyfree
pub fn cfg_dir() -> &'static str {
    static DIR: OnceLock<String> = OnceLock::new();
    DIR.get_or_init(|| std::env::var("MIHOMO_HOME").unwrap_or_else(|_| format!("{}/.config/mihomo", std::env::var("HOME").unwrap_or_default())))
}

pub fn cfg_path(name: &str) -> String { format!("{}/{name}", cfg_dir()) }
pub fn ctl() -> String { cfg_path("mihomoctl.sh") }

pub struct RunResult {
    pub status: i32,
    pub out: String,
}

/// 运行命令并合并 stdout/stderr。status 为 -1 表示无法执行，-2 表示超时（避免 curl 卡住导致菜单无响应）。
pub fn run(program: &str, args: &[&str], timeout: Duration) -> RunResult {
    let spawned = (|| {
        let (reader, writer) = std::io::pipe()?;
        let mut command = Command::new(program);
        command.args(args);
        if Path::new(cfg_dir()).is_dir() { command.current_dir(cfg_dir()); }
        command.env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")
            .env("AMYFREE_LANG", Language::current().code())
            .stdin(Stdio::null()).stdout(writer.try_clone()?).stderr(writer);
        let child = command.spawn()?;
        drop(command);   // 关闭本进程持有的写端，子进程退出后读端才能读到 EOF
        Ok::<_, std::io::Error>((child, reader))
    })();
    let (mut child, mut reader) = match spawned {
        Ok(value) => value,
        Err(error) => return RunResult { status: -1, out: tr("无法执行: ", "Could not run: ") + &error.to_string() },
    };
    let drain = thread::spawn(move || {
        let mut data = Vec::new();
        let _ = reader.read_to_end(&mut data);
        String::from_utf8_lossy(&data).into_owned()
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(-1),
            Ok(None) if Instant::now() > deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return RunResult { status: -2, out: tr("命令超时", "Command timed out") };
            }
            Ok(None) => thread::sleep(Duration::from_millis(50)),
            Err(_) => break -1,
        }
    };
    RunResult { status, out: drain.join().unwrap_or_default() }
}

pub fn run_default(program: &str, args: &[&str]) -> RunResult { run(program, args, Duration::from_secs(25)) }

pub fn api_secret() -> String {
    std::fs::read_to_string(cfg_path(".api-secret")).map(|text| text.trim().to_string()).unwrap_or_default()
}

fn agent(timeout: Duration, proxy: Option<&str>) -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .http_status_as_error(false)
        // 本地 API 不能走环境变量里的代理
        .proxy(proxy.and_then(|url| ureq::Proxy::new(url).ok()))
        .build().new_agent()
}

/// GET 本地 API 的路径（如 "/proxies/PROXY"），2xx 时返回正文。
pub fn http_get(path: &str, timeout: Duration) -> Option<String> {
    let secret = api_secret();
    let mut request = agent(timeout, None).get(format!("http://{API}{path}"));
    if !secret.is_empty() { request = request.header("Authorization", format!("Bearer {secret}")); }
    let mut response = request.call().ok()?;
    if !response.status().is_success() { return None; }
    response.body_mut().read_to_string().ok()
}

pub fn http_get_json(path: &str, timeout: Duration) -> Option<Value> {
    http_get(path, timeout).and_then(|text| serde_json::from_str(&text).ok())
}

pub fn http_delete(path: &str) -> bool {
    let secret = api_secret();
    let mut request = agent(Duration::from_secs(5), None).delete(format!("http://{API}{path}"));
    if !secret.is_empty() { request = request.header("Authorization", format!("Bearer {secret}")); }
    request.call().is_ok_and(|response| response.status().is_success())
}

/// 内核是否在运行
pub fn is_running() -> bool {
    let pid_file = cfg_path(".mihomo.pid");
    match std::fs::read_to_string(&pid_file) {
        Ok(text) => match text.trim().parse::<i32>() {
            // TUN 模式下内核以 root 运行，kill 返回 EPERM 也说明进程存在
            Ok(pid) => unsafe { libc::kill(pid, 0) == 0 || *libc::__error() == libc::EPERM },
            Err(_) => false,
        },
        // 旧版以 root 启动的内核会留下仅 root 可读的 pid 文件，改问本地 API
        Err(_) => Path::new(&pid_file).exists() && http_get("/version", Duration::from_secs(1)).is_some(),
    }
}

/// 通过代理拿出口 IP（顺带证明代理确实通）
pub fn fetch_exit_ip() -> Option<String> {
    let mut response = agent(Duration::from_secs(12), Some(PROXY_URL)).get("http://ip-api.com/line/?fields=query,country").call().ok()?;
    let text = response.body_mut().read_to_string().ok()?;
    Some(text.trim().replace('\n', " / "))
}

pub struct CurrentNode {
    pub name: String,
    pub delay: i64,
    pub fixed: Option<String>,
}

fn encode_path(text: &str) -> String {
    text.bytes().map(|byte| if byte.is_ascii_alphanumeric() { (byte as char).to_string() } else { format!("%{byte:02X}") }).collect()
}

/// 取实际承载代理流量的 PROXY 组：当前节点、延迟，以及是否被手工固定。
/// PROXY 是自动测速组，分流规则都指向它；菜单选节点时把它固定到所选节点，"自动选择"则解除固定。
pub fn fetch_current_node() -> Option<CurrentNode> {
    let group = http_get_json("/proxies/PROXY", Duration::from_secs(5))?;
    let name = group["now"].as_str().unwrap_or("-").to_string();
    // 固定的节点不可用时内核会临时改用最快节点，此时 now 与 fixed 不同
    let fixed = group["fixed"].as_str().filter(|value| !value.is_empty()).map(str::to_string);
    let last_delay = |value: &Value| value["history"].as_array().and_then(|history| history.last()).and_then(|last| last["delay"].as_i64()).unwrap_or(0);
    let mut delay = last_delay(&group);
    // 实测：Selector 组自身 history 常为空，此时改为查该节点自己的延迟
    if delay == 0 && name != "-" {
        if let Some(node) = http_get_json(&format!("/proxies/{}", encode_path(&name)), Duration::from_secs(5)) { delay = last_delay(&node); }
    }
    Some(CurrentNode { name, delay, fixed })
}

/// 节点提供者中的节点名
pub fn provider_node_names() -> Vec<String> {
    http_get_json("/providers/proxies/nodes", Duration::from_secs(5))
        .and_then(|value| value["proxies"].as_array().map(|nodes| nodes.iter().filter_map(|node| node["name"].as_str().map(str::to_string)).collect()))
        .unwrap_or_default()
}

/// 下载/上传累计字节数
pub fn traffic_totals() -> Option<(i64, i64)> {
    let value = http_get_json("/connections", Duration::from_secs(2))?;
    Some((value["downloadTotal"].as_i64()?, value["uploadTotal"].as_i64()?))
}

/// 取 TUN 是否开启
pub fn tun_enabled() -> bool {
    std::fs::read_to_string(cfg_path("config.yaml")).is_ok_and(|text| text.contains("\ntun:") || text.starts_with("tun:"))
}

/// 系统代理是否已开启（浏览器等 App 走代理的前提）
/// 逐个服务回读 networksetup，不依赖服务名，也不相信自己的状态文件
pub fn system_proxy_any_on() -> bool {
    let services = run_default("/usr/sbin/networksetup", &["-listallnetworkservices"]).out;
    services.lines().skip(1)
        .map(|line| line.strip_prefix('*').unwrap_or(line).trim())
        .filter(|service| !service.is_empty())
        .any(|service| run_default("/usr/sbin/networksetup", &["-getwebproxy", service]).out.contains("Enabled: Yes"))
}

/// 以管理员权限运行 tun.sh（系统弹出密码框）。提权后的 shell 不继承本进程环境，语言需显式传入。
pub fn run_tun_script(action: &str) -> RunResult {
    let command = format!("do shell script \"AMYFREE_LANG={} /bin/bash '{}' {action}\" with administrator privileges", Language::current().code(), cfg_path("tun.sh"));
    run("/usr/bin/osascript", &["-e", &command], Duration::from_secs(60))
}

/// 直接查询已安装的内核版本，服务停止时也能读取。
pub fn kernel_version() -> String {
    let binary = cfg_path("mihomo");
    let executable = std::fs::metadata(&binary).is_ok_and(|meta| { use std::os::unix::fs::PermissionsExt; meta.is_file() && meta.permissions().mode() & 0o111 != 0 });
    if !executable { return tr("未安装", "not installed"); }
    let result = run(&binary, &["-v"], Duration::from_secs(5));
    let version = result.out.split_whitespace().find(|token| token.starts_with('v') && token[1..].starts_with(|c: char| c.is_ascii_digit()));
    match version {
        Some(version) if result.status == 0 => format!("mihomo {version}"),
        _ if result.status == -2 => tr("读取超时", "timed out"),
        _ => tr("无法读取", "unreadable"),
    }
}

pub fn current_subscription() -> String {
    std::fs::read_to_string(cfg_path(".sub-url")).map(|text| text.trim().to_string()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_node_names_for_api_paths() {
        assert_eq!(encode_path("JP 1"), "JP%201");
        assert_eq!(encode_path("日本"), "%E6%97%A5%E6%9C%AC");
    }

    #[test]
    fn run_merges_output_and_reports_status() {
        let result = run("/bin/sh", &["-c", "echo out; echo err >&2; exit 3"], Duration::from_secs(5));
        assert_eq!(result.status, 3);
        assert!(result.out.contains("out") && result.out.contains("err"));
        assert_eq!(run("/bin/sleep", &["5"], Duration::from_millis(200)).status, -2);
    }
}
