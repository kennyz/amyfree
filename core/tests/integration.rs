//! Tests that use real sockets, processes and (when available) the real mihomo core.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use amyfree_core::cert::inspect_certificate;
use amyfree_core::geodata::{fetch, Metadata};
use amyfree_core::speed::latency_session;
use amyfree_core::support;
use serde_json::{json, Value};

fn object(value: Value) -> serde_json::Map<String, Value> {
    value.as_object().unwrap().clone()
}

/// A failed rule data download is reported as an error.
#[test]
fn http_failure_is_reported() {
    let directory = tempfile::tempdir().unwrap();
    let port = support::free_port();
    let result = fetch(&format!("https://127.0.0.1:{port}/data"), &directory.path().join("download"), None, &Metadata::default());
    assert!(result.is_err());
}

/// A self-signed certificate is read without trusting it: dates are reported, state is "untrusted".
#[cfg(unix)]
#[test]
fn local_tls_certificate_dates_are_read_without_trusting_self_signed() {
    let directory = tempfile::tempdir().unwrap();
    let (cert, key) = (directory.path().join("cert.pem"), directory.path().join("key.pem"));
    let created = Command::new("/usr/bin/openssl")
        .args(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "10", "-subj", "/CN=localhost", "-keyout"])
        .arg(&key)
        .arg("-out")
        .arg(&cert)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(created.success());
    let port = support::free_port();
    let mut server = Command::new("/usr/bin/openssl")
        .args(["s_server", "-quiet", "-accept", &port.to_string(), "-cert"])
        .arg(&cert)
        .arg("-key")
        .arg(&key)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    for _ in 0..50 {
        if support::can_connect(port) {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    let result = inspect_certificate(&object(json!({"type": "trojan", "server": "127.0.0.1", "port": port, "sni": "localhost"})), Duration::from_secs(3));
    let _ = server.kill();
    let _ = server.wait();
    assert_eq!(result["state"], "untrusted", "{result:?}");
    assert_eq!(result["trusted"], false);
    assert!(result["days_left"].as_i64().unwrap() > 0);
    assert!(result.contains_key("not_after"));
}

fn core_binary() -> Option<PathBuf> {
    let candidates = [
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../mihomo").join(amyfree_core::paths::CORE_BINARY),
        dirs_home().join(".config/mihomo").join(amyfree_core::paths::CORE_BINARY),
    ];
    candidates.into_iter().find(|path| path.is_file())
}

fn dirs_home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

/// An HTTP proxy whose CONNECT takes 650 ms, after which each request is answered quickly.
fn slow_handshake_proxy() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            thread::spawn(move || {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let mut writer = stream.try_clone().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() || !line.starts_with("CONNECT ") {
                    return;
                }
                let skip_headers = |reader: &mut BufReader<_>| loop {
                    let mut header = String::new();
                    match reader.read_line(&mut header) {
                        Ok(0) | Err(_) => return false,
                        Ok(_) if header == "\r\n" || header == "\n" => return true,
                        _ => {}
                    }
                };
                if !skip_headers(&mut reader) {
                    return;
                }
                thread::sleep(Duration::from_millis(650));
                let _ = writer.write_all(b"HTTP/1.1 200 Connection established\r\n\r\n");
                loop {
                    let mut request = String::new();
                    if reader.read_line(&mut request).map(|read| read == 0).unwrap_or(true) || !skip_headers(&mut reader) {
                        return;
                    }
                    thread::sleep(Duration::from_millis(15));
                    if writer.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n").is_err() {
                        return;
                    }
                }
            });
        }
    });
    port
}

/// With the real core: the unified delay metric must not count slow connection setup as latency.
#[test]
fn unified_metric_excludes_slow_connection_setup() {
    let Some(core) = core_binary() else {
        eprintln!("skipped: no mihomo core found");
        return;
    };
    let proxy_port = slow_handshake_proxy();
    let directory = tempfile::tempdir().unwrap();
    let home = directory.path();
    std::fs::create_dir_all(home.join("providers")).unwrap();
    // A symlink avoids the first-launch security scan a freshly copied executable gets on macOS.
    #[cfg(unix)]
    std::os::unix::fs::symlink(&core, home.join(amyfree_core::paths::CORE_BINARY)).unwrap();
    #[cfg(not(unix))]
    std::fs::copy(&core, home.join(amyfree_core::paths::CORE_BINARY)).unwrap();
    let nodes = json!({"proxies": [{"name": "fixture", "type": "http", "server": "127.0.0.1", "port": proxy_port}]});
    std::fs::write(home.join("providers/nodes.yaml"), nodes.to_string()).unwrap();
    let mut measured = Vec::new();
    for unified in [false, true] {
        let delay = latency_session(home, unified, |api, secret| {
            let url = format!("http://{api}/proxies/fixture/delay?url={}&timeout=3000", support::url_escape("http://probe.invalid/check"));
            let authorization = format!("Bearer {secret}");
            let response = support::http("GET", &url, &[("Authorization", authorization.as_str())], None, Duration::from_secs(5))?;
            Ok(response.json().and_then(|value| value["delay"].as_i64()).unwrap_or(0))
        })
        .unwrap();
        measured.push(delay);
    }
    assert!(measured[0] >= 600, "first-request time {measured:?}");
    assert!(measured[1] > 0 && measured[1] < 200, "unified delay {measured:?}");
    eprintln!("slow-handshake regression: first request {} ms, unified response delay {} ms", measured[0], measured[1]);
}
