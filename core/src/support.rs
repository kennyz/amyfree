//! Shared plumbing: user-facing errors, atomic files, processes, locking and local HTTP.

use std::collections::BTreeMap;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

/// Message language follows AMYFREE_LANG ("en" or default Chinese), as passed by the app.
pub fn t(zh: &str, en: &str) -> String {
    if std::env::var("AMYFREE_LANG").as_deref() == Ok("en") { en.to_string() } else { zh.to_string() }
}

/// An error whose message is safe to show the user (never contains credentials).
#[derive(Debug, Clone, PartialEq)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

pub fn fail<T>(message: String) -> Result<T> {
    Err(Error(message))
}

/// Maps any lower-level error to a fixed, credential-free message.
pub trait Context<T> {
    fn or_msg(self, message: String) -> Result<T>;
}

impl<T, E> Context<T> for std::result::Result<T, E> {
    fn or_msg(self, message: String) -> Result<T> {
        self.map_err(|_| Error(message))
    }
}

impl<T> Context<T> for Option<T> {
    fn or_msg(self, message: String) -> Result<T> {
        self.ok_or(Error(message))
    }
}

// ---------------------------------------------------------------------------
// Files

pub fn read_text(path: &Path) -> Option<String> {
    fs::read(path).ok().map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

fn private_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// Writes a temporary file beside the target, then renames it into place (mode 0600 on Unix).
pub fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    let failure = || t("无法写入配置文件。", "Could not write the config file.");
    let parent = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent).or_msg(failure())?;
    let temporary = parent.join(format!(".sub-write-{}", random_hex(6)));
    let result = (|| -> std::io::Result<()> {
        let mut file = private_file(&temporary)?;
        file.write_all(data)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.or_msg(failure())
}

pub type Snapshot = BTreeMap<PathBuf, Option<Vec<u8>>>;

pub fn snapshot<'a>(paths: impl IntoIterator<Item = &'a PathBuf>) -> Snapshot {
    paths.into_iter().map(|path| (path.clone(), fs::read(path).ok())).collect()
}

/// Puts files back as they were (None = the file did not exist).
pub fn restore(snapshot: &Snapshot) -> Result<()> {
    for (path, content) in snapshot {
        match content {
            Some(data) => atomic_write(path, data)?,
            None if path.exists() => fs::remove_file(path).or_msg(t("恢复配置文件失败。", "Could not restore config files."))?,
            None => {}
        }
    }
    Ok(())
}

/// A private temporary directory, removed on drop.
pub fn temp_dir(prefix: &str, parent: Option<&Path>) -> Result<tempfile::TempDir> {
    let mut builder = tempfile::Builder::new();
    builder.prefix(prefix);
    match parent {
        Some(parent) => builder.tempdir_in(parent),
        None => builder.tempdir(),
    }
    .or_msg(t("无法创建临时目录。", "Could not create a temporary folder."))
}

pub fn random_hex(bytes: usize) -> String {
    let mut data = vec![0u8; bytes];
    rand::fill(&mut data[..]);
    data.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Exclusive, non-blocking lock on a file whose inode never changes; released when the File drops.
pub fn try_lock(path: &Path) -> Option<File> {
    let file = OpenOptions::new().create(true).append(true).open(path).ok()?;
    file.try_lock().ok()?;
    Some(file)
}

// ---------------------------------------------------------------------------
// Processes

pub struct Output {
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub timed_out: bool,
}

impl Output {
    pub fn success(&self) -> bool {
        self.status == Some(0) && !self.timed_out
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }
}

/// Runs a program to completion (stderr discarded), killing it after `timeout`.
pub fn run(program: &Path, args: &[&str], timeout: Duration) -> Output {
    let spawned = Command::new(program).args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn();
    let Ok(mut child) = spawned else {
        return Output { status: None, stdout: Vec::new(), timed_out: false };
    };
    let mut pipe = child.stdout.take();
    let reader = thread::spawn(move || {
        let mut buffer = Vec::new();
        if let Some(pipe) = pipe.as_mut() {
            let _ = pipe.read_to_end(&mut buffer);
        }
        buffer
    });
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code(),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            _ => {
                timed_out = true;
                let _ = child.kill();
                break child.wait().ok().and_then(|status| status.code());
            }
        }
    };
    let stdout = reader.join().unwrap_or_default();
    Output { status, stdout, timed_out }
}

#[cfg(unix)]
fn detach(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    // A new session: the child survives the calling shell or app exiting and gets none of its signals.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

#[cfg(windows)]
fn detach(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
}

fn log_file(path: &Path, append: bool) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).write(true);
    if append { options.append(true) } else { options.truncate(true) };
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// Starts a long-running program detached from the caller, with output appended to a log.
pub fn spawn_detached(program: &Path, args: &[&str], log: &Path, directory: &Path) -> Result<u32> {
    let failure = || t("无法创建后台内核进程", "Could not start the core process");
    let output = log_file(log, true).or_msg(failure())?;
    let errors = output.try_clone().or_msg(failure())?;
    let mut command = Command::new(program);
    command.args(args).current_dir(directory).stdin(Stdio::null()).stdout(output).stderr(errors);
    detach(&mut command);
    let child = command.spawn().or_msg(failure())?;
    Ok(child.id())
}

/// Children we own (isolated test sessions); stopped on drop and on SIGTERM.
pub struct ChildProcess {
    child: Child,
}

fn live_children() -> &'static Mutex<Vec<u32>> {
    static LIVE: OnceLock<Mutex<Vec<u32>>> = OnceLock::new();
    LIVE.get_or_init(|| Mutex::new(Vec::new()))
}

impl ChildProcess {
    pub fn spawn(program: &Path, args: &[&str], log: &Path) -> Result<ChildProcess> {
        let failure = || t("检测会话无法启动", "Could not start the test session");
        let output = log_file(log, false).or_msg(failure())?;
        let errors = output.try_clone().or_msg(failure())?;
        let mut command = Command::new(program);
        command.args(args).stdin(Stdio::null()).stdout(output).stderr(errors);
        detach(&mut command);
        let child = command.spawn().or_msg(failure())?;
        live_children().lock().unwrap().push(child.id());
        Ok(ChildProcess { child })
    }

    pub fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    pub fn stop(&mut self) {
        if self.is_running() {
            terminate(self.child.id());
            let deadline = Instant::now() + Duration::from_secs(2);
            while self.is_running() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(50));
            }
            if self.is_running() {
                let _ = self.child.kill();
            }
        }
        let _ = self.child.wait();
        live_children().lock().unwrap().retain(|pid| *pid != self.child.id());
    }
}

impl Drop for ChildProcess {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(unix)]
fn terminate(pid: u32) {
    unsafe {
        libc::kill(pid as i32, libc::SIGTERM);
    }
}

#[cfg(windows)]
fn terminate(pid: u32) {
    let _ = Command::new("taskkill").args(["/PID", &pid.to_string(), "/T", "/F"]).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

/// When the app cancels us with SIGTERM, take isolated cores down too before exiting.
pub fn install_termination_handler() {
    #[cfg(unix)]
    {
        use signal_hook::consts::SIGTERM;
        use signal_hook::iterator::Signals;
        if let Ok(mut signals) = Signals::new([SIGTERM]) {
            thread::spawn(move || {
                if signals.forever().next().is_some() {
                    let pids = live_children().lock().map(|list| list.clone()).unwrap_or_default();
                    for pid in &pids {
                        terminate(*pid);
                    }
                    thread::sleep(Duration::from_millis(300));
                    for pid in &pids {
                        unsafe {
                            libc::kill(*pid as i32, libc::SIGKILL);
                        }
                    }
                    std::process::exit(143);
                }
            });
        }
    }
}

/// Is the main core running, according to its pid file? (EPERM means it runs as root for TUN.)
pub fn core_running(directory: &Path) -> bool {
    let Some(pid) = read_text(&directory.join(".mihomo.pid")).and_then(|text| text.trim().parse::<u32>().ok()) else {
        return false;
    };
    process_alive(pid)
}

#[cfg(unix)]
pub fn process_alive(pid: u32) -> bool {
    let alive = unsafe { libc::kill(pid as i32, 0) == 0 };
    alive || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(windows)]
pub fn process_alive(pid: u32) -> bool {
    Command::new("tasklist")
        .args(["/FI", &format!("PID eq {pid}"), "/NH"])
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).contains(&pid.to_string()))
        .unwrap_or(false)
}

pub fn api_secret(directory: &Path) -> String {
    read_text(&directory.join(".api-secret")).map(|text| text.trim().to_string()).unwrap_or_default()
}

pub fn api_address() -> String {
    std::env::var("MIHOMO_API").unwrap_or_else(|_| "127.0.0.1:9090".into())
}

// ---------------------------------------------------------------------------
// Networking

pub fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").and_then(|listener| listener.local_addr()).map(|address| address.port()).unwrap_or(0)
}

pub fn can_connect(port: u16) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&address, Duration::from_millis(100)).is_ok()
}

pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

/// Direct HTTP request (never through a proxy), for the local mihomo API. Non-2xx statuses are returned, not errors.
pub fn http(method: &str, url: &str, headers: &[(&str, &str)], body: Option<&[u8]>, timeout: Duration) -> Result<HttpResponse> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .http_status_as_error(false)
        .proxy(None)
        .build()
        .into();
    let failure = || "request failed".to_string();
    let response = match method {
        "PUT" => {
            let mut request = agent.put(url);
            for (key, value) in headers {
                request = request.header(*key, *value);
            }
            match body {
                Some(data) => request.send(data),
                None => request.send_empty(),
            }
        }
        _ => {
            let mut request = agent.get(url);
            for (key, value) in headers {
                request = request.header(*key, *value);
            }
            request.call()
        }
    };
    let mut response = response.or_msg(failure())?;
    let status = response.status().as_u16();
    let body = response.body_mut().read_to_vec().unwrap_or_default();
    Ok(HttpResponse { status, body })
}

pub fn url_escape(text: &str) -> String {
    const SET: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');
    percent_encoding::utf8_percent_encode(text, SET).to_string()
}

/// Prints a line to stdout and flushes (progress output is read live).
pub fn say(text: &str) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{text}");
    let _ = stdout.flush();
}
