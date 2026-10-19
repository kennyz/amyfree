//! Latency checks and short download speed tests in isolated proxy sessions; the main proxy is never switched.

use std::path::Path;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use serde_json::{json, Map, Value};

use crate::chain::{chain_nodes, read_state, EXIT};
use crate::subscription::{name_of, parse_subscription_file, Proxy};
use crate::support::{self, atomic_write, fail, t, ChildProcess, Error, Result};
use crate::yaml::to_yaml;

pub const SAMPLE_BYTES: u64 = 1_000_000;
const DOWNLOAD_URL: &str = "https://speed.cloudflare.com/__down?bytes=1000000";

/// Maps items with up to `workers` threads, keeping the input order.
pub fn parallel_map<T: Sync, R: Send>(items: &[T], workers: usize, work: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let next = Mutex::new(0usize);
    let results: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    thread::scope(|scope| {
        for _ in 0..workers.max(1).min(items.len().max(1)) {
            scope.spawn(|| loop {
                let index = {
                    let mut next = next.lock().unwrap();
                    let index = *next;
                    *next += 1;
                    index
                };
                if index >= items.len() {
                    break;
                }
                let value = work(&items[index]);
                results.lock().unwrap()[index] = Some(value);
            });
        }
    });
    results.into_inner().unwrap().into_iter().map(|value| value.expect("every item is processed")).collect()
}

fn probe_dns() -> Value {
    // Don't borrow the system's fake-IP resolver, or a chain exit could be dialed to an unroutable fake IP.
    let doh = json!(["https://dns.alidns.com/dns-query"]);
    json!({"enable": true, "listen": "127.0.0.1:0", "ipv6": false, "enhanced-mode": "redir-host", "respect-rules": false,
           "default-nameserver": ["223.5.5.5", "119.29.29.29"], "nameserver": doh, "proxy-server-nameserver": doh, "direct-nameserver": doh})
}

/// Changes whenever the node list or chain settings change.
pub fn fingerprint(directory: &Path) -> String {
    let describe = |path: &Path| {
        std::fs::metadata(path).ok().map(|metadata| {
            let modified = metadata.modified().ok().and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok()).map(|age| age.as_nanos()).unwrap_or(0);
            #[cfg(unix)]
            let inode = std::os::unix::fs::MetadataExt::ino(&metadata);
            #[cfg(not(unix))]
            let inode = 0u64;
            (inode, modified, metadata.len())
        })
    };
    let Some((inode, modified, size)) = describe(&directory.join("providers/nodes.yaml")) else { return "missing".into() };
    let mut result = format!("{inode}:{modified}:{size}");
    if let Some((_, chain_modified, chain_size)) = describe(&directory.join(".mimio-chain.json")) {
        result += &format!(":{chain_modified}:{chain_size}");
    }
    result
}

pub fn catalogue(directory: &Path) -> Result<Map<String, Value>> {
    let proxies = parse_subscription_file(&directory.join("providers/nodes.yaml"))?;
    let state = read_state(directory)?;
    let mut names: Vec<Value> = proxies.iter().map(|proxy| json!(name_of(proxy))).collect();
    let mut labels = Map::new();
    if state.get("enabled").and_then(Value::as_bool) == Some(true) {
        names.push(json!(EXIT));
        let text = |key: &str| state.get(key).and_then(Value::as_str).unwrap_or("").to_string();
        labels.insert(EXIT.into(), json!(t("链式代理 · ", "Chain proxy · ") + &text("entry") + " → " + &text("exit")));
    }
    Ok(json!({"fingerprint": fingerprint(directory), "names": names, "labels": labels, "chain": state}).as_object().unwrap().clone())
}

/// URL tests time the second response on the same connection, so first-time DNS/TCP/TLS cost isn't counted as RTT.
pub fn latency_config(proxies: &[Proxy], port: u16, secret: &str, unified_delay: bool) -> Map<String, Value> {
    json!({"mixed-port": 0, "external-controller": format!("127.0.0.1:{port}"), "secret": secret, "allow-lan": false,
           "mode": "rule", "log-level": "error", "ipv6": false, "unified-delay": unified_delay, "dns": probe_dns(),
           "proxies": proxies, "rules": ["MATCH,DIRECT"]})
    .as_object()
    .unwrap()
    .clone()
}

/// Starts an isolated core with `config`, waits for `port`, runs `body`, then stops the core.
pub fn with_isolated_core<T>(directory: &Path, config: &Map<String, Value>, port: u16, prefix: &str, failure: String, body: impl FnOnce() -> Result<T>) -> Result<T> {
    let work = support::temp_dir(prefix, None)?;
    let path = work.path().join("config.yaml");
    atomic_write(&path, (to_yaml(config, 0) + "\n").as_bytes())?;
    let (work_text, path_text) = (work.path().to_string_lossy().into_owned(), path.to_string_lossy().into_owned());
    let mut child = ChildProcess::spawn(&directory.join(crate::paths::CORE_BINARY), &["-d", &work_text, "-f", &path_text], &work.path().join("private.log"))?;
    let mut ready = false;
    for _ in 0..100 {
        if !child.is_running() {
            break;
        }
        if support::can_connect(port) {
            ready = true;
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    if !ready {
        child.stop();
        return Err(Error(failure));
    }
    let result = body();
    child.stop();
    result
}

pub fn latency_session<T>(directory: &Path, unified_delay: bool, body: impl FnOnce(&str, &str) -> Result<T>) -> Result<T> {
    let mut proxies = parse_subscription_file(&directory.join("providers/nodes.yaml"))?;
    let state = read_state(directory)?;
    if state.get("enabled").and_then(Value::as_bool) == Some(true) {
        let text = |key: &str| state.get(key).and_then(Value::as_str).unwrap_or("").to_string();
        proxies.extend(chain_nodes(&proxies, &text("entry"), &text("exit"))?);
    }
    let port = support::free_port();
    let secret = support::random_hex(20);
    let config = latency_config(&proxies, port, &secret, unified_delay);
    let api = format!("127.0.0.1:{port}");
    with_isolated_core(directory, &config, port, "mimio-latency-", t("检测会话启动超时", "The test session timed out while starting"), || body(&api, &secret))
}

pub fn check_latencies(names: &[String], api: &str, secret: &str) -> Vec<Value> {
    let query = format!("timeout=6000&url={}", support::url_escape("https://www.gstatic.com/generate_204"));
    let authorization = format!("Bearer {secret}");
    parallel_map(names, 3, |name| {
        let url = format!("http://{api}/proxies/{}/delay?{query}", support::url_escape(name));
        match support::http("GET", &url, &[("Authorization", authorization.as_str())], None, Duration::from_secs(8)) {
            Ok(response) if response.status == 200 => {
                let delay = response.json().and_then(|value| value.get("delay").and_then(Value::as_i64)).unwrap_or(0);
                json!({"name": name, "delay": delay, "error": if delay > 0 { String::new() } else { t("检测未通过", "Test failed") }})
            }
            Ok(response) => {
                let service = matches!(response.status, 401 | 404);
                let error = if service { t("节点更新中", "Node updating") } else { t("超时或连接失败", "Timed out or connection failed") };
                json!({"name": name, "delay": 0, "error": error, "service_error": service})
            }
            Err(_) => json!({"name": name, "delay": 0, "error": t("内核连接中断", "Lost connection to the core"), "service_error": true}),
        }
    })
}

/// Latency for every node plus certificate checks, independent of the main proxy so url-test groups never switch.
pub fn latency_batch(directory: &Path) -> Result<Map<String, Value>> {
    let mut result = catalogue(directory)?;
    let names: Vec<String> = result["names"].as_array().unwrap().iter().filter_map(Value::as_str).map(str::to_string).collect();
    let (latencies, certificates) = thread::scope(|scope| {
        let certificates = scope.spawn(|| crate::cert::certificate_batch(directory));
        let latencies = latency_session(directory, true, |api, secret| Ok(check_latencies(&names, api, secret)));
        (latencies, certificates.join().unwrap_or_else(|_| fail("certificate check failed".into())))
    });
    result.insert("paused".into(), json!(false));
    result.insert("results".into(), Value::Array(latencies?));
    result.insert("certificates".into(), Value::Object(certificates?));
    Ok(result)
}

pub fn speed_from_sample(status: u16, received: u64, seconds: f64) -> Result<f64> {
    if status != 200 || received != SAMPLE_BYTES || seconds <= 0.0 {
        return fail(t("下载样本未完成", "Download sample incomplete"));
    }
    Ok(received as f64 / seconds / 1_000_000.0)
}

pub fn measure(directory: &Path, name: &str) -> Result<Map<String, Value>> {
    let mut proxies = parse_subscription_file(&directory.join("providers/nodes.yaml"))?;
    if name == EXIT {
        let state = read_state(directory)?;
        if state.get("enabled").and_then(Value::as_bool) != Some(true) {
            return fail(t("链式代理未开启", "Chain proxy is off"));
        }
        let text = |key: &str| state.get(key).and_then(Value::as_str).unwrap_or("").to_string();
        proxies.extend(chain_nodes(&proxies, &text("entry"), &text("exit"))?);
    }
    if !proxies.iter().any(|proxy| name_of(proxy) == name) {
        return fail(t("订阅节点已变化，请重新检测", "Subscription nodes changed. Test again."));
    }
    let port = support::free_port();
    // Only the chosen node, forced by MATCH; no TUN, controller or system proxy changes.
    let config = json!({"mixed-port": port, "bind-address": "127.0.0.1", "allow-lan": false, "mode": "rule", "log-level": "error",
                        "ipv6": false, "dns": probe_dns(), "proxies": proxies,
                        "proxy-groups": [{"name": "MIMIO_SPEED_TEST", "type": "select", "proxies": [name]}],
                        "rules": ["MATCH,MIMIO_SPEED_TEST"]});
    let failure = t("无法启动隔离测速会话", "Could not start an isolated speed-test session");
    with_isolated_core(directory, config.as_object().unwrap(), port, "mimio-download-", failure, || {
        let proxy = format!("http://127.0.0.1:{port}");
        let result = support::run(
            Path::new(crate::paths::CURL),
            &["-sS", "--proxy", &proxy, "--noproxy", "", "--connect-timeout", "6", "--max-time", "12", "-H", "Accept-Encoding: identity",
              "-o", if cfg!(windows) { "NUL" } else { "/dev/null" }, "-w", "%{http_code} %{size_download} %{time_total}", DOWNLOAD_URL],
            Duration::from_secs(14),
        );
        if !result.success() {
            return fail(t("下载测速超时或连接失败", "Download test timed out or the connection failed"));
        }
        let text = result.text();
        let parts: Vec<&str> = text.split_whitespace().collect();
        let (Some(status), Some(received), Some(seconds)) = (
            parts.first().and_then(|value| value.parse::<u16>().ok()),
            parts.get(1).and_then(|value| value.parse::<f64>().ok()),
            parts.get(2).and_then(|value| value.parse::<f64>().ok()),
        ) else {
            return fail(t("下载样本未完成", "Download sample incomplete"));
        };
        let speed = speed_from_sample(status, received as u64, seconds)?;
        Ok(json!({"ok": true, "megabytes_per_second": speed, "bytes": SAMPLE_BYTES, "seconds": seconds}).as_object().unwrap().clone())
    })
}

/// `mihomoctl.sh nodes`: node list and latency from the running core.
pub fn list_nodes(provider: &str, api: &str, secret: &str) -> i32 {
    let authorization = format!("Bearer {secret}");
    let headers: Vec<(&str, &str)> = if secret.is_empty() { vec![] } else { vec![("Authorization", authorization.as_str())] };
    let url = format!("http://{api}/providers/proxies/{provider}");
    let Some(proxies) = support::http("GET", &url, &headers, None, Duration::from_secs(6))
        .ok()
        .filter(|response| response.status == 200)
        .and_then(|response| response.json())
        .and_then(|value| value.get("proxies").and_then(Value::as_array).cloned())
    else {
        support::say(&t("✗ 无法获取 provider 数据", "✗ Could not fetch provider data"));
        return 1;
    };
    if proxies.is_empty() {
        support::say(&t("(订阅中没有任何节点 —— 检查订阅格式或链接是否有效)", "(The subscription has no nodes. Check its format or link.)"));
        return 1;
    }
    support::say(&t(&format!("provider: {provider}   节点数: {}", proxies.len()), &format!("provider: {provider}   nodes: {}", proxies.len())));
    support::say(&"-".repeat(56));
    let mut alive = 0;
    for (index, proxy) in proxies.iter().enumerate() {
        let delay = match proxy.get("history").and_then(Value::as_array).and_then(|history| history.last()) {
            Some(last) => match last.get("delay").and_then(Value::as_i64).unwrap_or(0) {
                0 => t("超时", "timeout"),
                value => format!("{value} ms"),
            },
            None => t("未测速", "not tested"),
        };
        let ok = proxy.get("alive").and_then(Value::as_bool) == Some(true);
        if ok {
            alive += 1;
        }
        let name = proxy.get("name").and_then(Value::as_str).unwrap_or("?");
        support::say(&format!("{:3}. [{}] {:<34} {}", index + 1, if ok { "OK " } else { "DEAD" }, name, delay));
    }
    support::say(&"-".repeat(56));
    support::say(&t(&format!("可用: {alive}/{}", proxies.len()), &format!("Available: {alive}/{}", proxies.len())));
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speed_units_and_invalid_samples() {
        assert_eq!(speed_from_sample(200, SAMPLE_BYTES, 2.0).unwrap(), 0.5);
        assert_eq!(speed_from_sample(200, SAMPLE_BYTES, 0.25).unwrap(), 4.0);
        for (status, received, seconds) in [(500, SAMPLE_BYTES, 1.0), (200, 100, 1.0), (200, SAMPLE_BYTES, 0.0)] {
            assert!(speed_from_sample(status, received, seconds).is_err());
        }
    }

    #[test]
    fn parallel_map_keeps_order() {
        let items: Vec<u32> = (0..20).collect();
        assert_eq!(parallel_map(&items, 3, |value| value * 2), (0..20).map(|value| value * 2).collect::<Vec<_>>());
        assert!(parallel_map(&Vec::<u32>::new(), 3, |value| *value).is_empty());
    }
}
