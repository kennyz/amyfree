//! Subscription parsing (Clash YAML/JSON, plain or base64 share links) and the update transaction.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine;
use serde_json::{json, Map, Value};

use crate::support::{self, atomic_write, fail, read_text, restore, say, snapshot, t, Context, Error, Result};
use crate::yaml::{parse_yaml, to_yaml};

pub type Proxy = Map<String, Value>;

pub fn name_of(proxy: &Proxy) -> &str {
    proxy.get("name").and_then(Value::as_str).unwrap_or("")
}

pub fn type_of(proxy: &Proxy) -> &str {
    proxy.get("type").and_then(Value::as_str).unwrap_or("")
}

// ---------------------------------------------------------------------------
// Validation

/// Safe YAML/JSON load; the error never echoes subscription content.
pub fn load_yaml(text: &str) -> Result<Value> {
    parse_yaml(text).or_msg(t("订阅 YAML 格式不正确或含不支持的对象。", "The subscription YAML is malformed or contains unsupported objects."))
}

pub fn validate_proxies(value: Option<&Value>) -> Result<Vec<Proxy>> {
    let Some(Value::Array(items)) = value else {
        return fail(t("订阅中没有可用的 proxies 节点列表。", "The subscription has no usable proxies list."));
    };
    if items.is_empty() {
        return fail(t("订阅中没有可用的 proxies 节点列表。", "The subscription has no usable proxies list."));
    }
    let mut names = HashSet::new();
    let mut proxies = Vec::new();
    for (offset, item) in items.iter().enumerate() {
        let index = offset + 1;
        let Value::Object(proxy) = item else {
            return fail(t(&format!("第 {index} 个节点不是有效配置。"), &format!("Node {index} is not a valid config.")));
        };
        for key in ["name", "type"] {
            if !proxy.get(key).and_then(Value::as_str).is_some_and(|text| !text.trim().is_empty()) {
                return fail(t(&format!("第 {index} 个节点缺少有效的 {key} 字段。"), &format!("Node {index} is missing a valid {key} field.")));
            }
        }
        if !names.insert(name_of(proxy).to_string()) {
            return fail(t(&format!("第 {index} 个节点与前面的节点重名，请修正订阅。"), &format!("Node {index} has the same name as an earlier node. Fix the subscription.")));
        }
        if !matches!(type_of(proxy), "direct" | "reject") {
            if !proxy.get("server").and_then(Value::as_str).is_some_and(|text| !text.trim().is_empty()) {
                return fail(t(&format!("第 {index} 个节点缺少服务器地址。"), &format!("Node {index} is missing a server address.")));
            }
            if !proxy.get("port").and_then(Value::as_i64).is_some_and(|port| (1..=65535).contains(&port)) {
                return fail(t(&format!("第 {index} 个节点端口不正确。"), &format!("Node {index} has an invalid port.")));
            }
        }
        proxies.push(proxy.clone());
    }
    Ok(proxies)
}

// ---------------------------------------------------------------------------
// Share links

struct Link {
    host: String,
    port: u16,
    user: String,
    query: HashMap<String, String>,
    name: String,
}

fn percent_decode(text: &str) -> String {
    percent_encoding::percent_decode_str(text).decode_utf8_lossy().into_owned()
}

fn parse_link(line: &str, default_name: &str) -> Result<Link> {
    let malformed = || "malformed link".to_string();
    let url = url::Url::parse(line).or_msg(malformed())?;
    let host = url.host_str().filter(|host| !host.is_empty()).or_msg(malformed())?;
    let port = url.port().or_msg(malformed())?;
    // Like Python's parse_qs: the first value wins and blank values are ignored.
    let mut query = HashMap::new();
    for (key, value) in url.query_pairs() {
        if !value.is_empty() {
            query.entry(key.into_owned()).or_insert_with(|| value.into_owned());
        }
    }
    let name = url.fragment().map(percent_decode).filter(|name| !name.is_empty()).unwrap_or_else(|| default_name.to_string());
    Ok(Link {
        host: host.trim_start_matches('[').trim_end_matches(']').to_string(),
        port,
        user: percent_decode(url.username()),
        query,
        name,
    })
}

fn split_list(text: &str) -> Value {
    Value::Array(text.split(',').map(|item| Value::String(item.to_string())).collect())
}

fn ws_options(query: &HashMap<String, String>) -> Value {
    let mut options = Map::new();
    if let Some(path) = query.get("path") {
        options.insert("path".into(), json!(path));
    }
    if let Some(host) = query.get("host") {
        options.insert("headers".into(), json!({ "Host": host }));
    }
    Value::Object(options)
}

pub fn parse_vless(line: &str) -> Result<Proxy> {
    let link = parse_link(line, "vless")?;
    let query = &link.query;
    let mut proxy = Proxy::new();
    proxy.insert("name".into(), json!(link.name));
    proxy.insert("type".into(), json!("vless"));
    proxy.insert("server".into(), json!(link.host));
    proxy.insert("port".into(), json!(link.port));
    proxy.insert("uuid".into(), json!(link.user));
    proxy.insert("udp".into(), json!(true));
    match query.get("type").map(String::as_str).unwrap_or("tcp") {
        "ws" => {
            proxy.insert("network".into(), json!("ws"));
            proxy.insert("ws-opts".into(), ws_options(query));
        }
        "grpc" => {
            proxy.insert("network".into(), json!("grpc"));
            proxy.insert("grpc-opts".into(), json!({ "grpc-service-name": query.get("serviceName").cloned().unwrap_or_default() }));
        }
        _ => {
            proxy.insert("network".into(), json!("tcp"));
        }
    }
    let security = query.get("security").map(String::as_str).unwrap_or("none");
    if security == "tls" {
        proxy.insert("tls".into(), json!(true));
        if let Some(sni) = query.get("sni") {
            proxy.insert("servername".into(), json!(sni));
        }
        if let Some(fingerprint) = query.get("fp") {
            proxy.insert("client-fingerprint".into(), json!(fingerprint));
        }
        if let Some(alpn) = query.get("alpn") {
            proxy.insert("alpn".into(), split_list(alpn));
        }
    }
    if let Some(flow) = query.get("flow") {
        proxy.insert("flow".into(), json!(flow));
    }
    if security == "reality" {
        proxy.insert("tls".into(), json!(true));
        let mut reality = Map::new();
        if let Some(key) = query.get("pbk") {
            reality.insert("public-key".into(), json!(key));
        }
        if let Some(id) = query.get("sid") {
            reality.insert("short-id".into(), json!(id));
        }
        if !reality.is_empty() {
            proxy.insert("reality-opts".into(), Value::Object(reality));
        }
        if let Some(sni) = query.get("sni") {
            proxy.insert("servername".into(), json!(sni));
        }
    }
    Ok(proxy)
}

pub fn parse_trojan(line: &str) -> Result<Proxy> {
    let link = parse_link(line, "trojan")?;
    let query = &link.query;
    let mut proxy = Proxy::new();
    proxy.insert("name".into(), json!(link.name));
    proxy.insert("type".into(), json!("trojan"));
    proxy.insert("server".into(), json!(link.host));
    proxy.insert("port".into(), json!(link.port));
    proxy.insert("password".into(), json!(link.user));
    proxy.insert("udp".into(), json!(true));
    proxy.insert("skip-cert-verify".into(), json!(query.get("allowInsecure").map(String::as_str) == Some("1")));
    if let Some(sni) = query.get("sni").or_else(|| query.get("peer")) {
        proxy.insert("sni".into(), json!(sni));
    }
    if query.get("type").map(String::as_str) == Some("ws") {
        proxy.insert("network".into(), json!("ws"));
        proxy.insert("ws-opts".into(), ws_options(query));
    }
    if let Some(alpn) = query.get("alpn") {
        proxy.insert("alpn".into(), split_list(alpn));
    }
    Ok(proxy)
}

/// Lenient base64 (standard or URL-safe alphabet, padding optional).
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut value: String = text.chars().filter(|c| !c.is_whitespace()).map(|c| match c { '-' => '+', '_' => '/', other => other }).collect();
    while value.len() % 4 != 0 {
        value.push('=');
    }
    base64::engine::general_purpose::STANDARD.decode(value).ok()
}

pub fn parse_shadowsocks(line: &str) -> Result<Proxy> {
    let malformed = || t("无法解析 Shadowsocks 链接", "Could not parse the Shadowsocks link");
    let rest = &line[5..];
    let (body, fragment) = rest.split_once('#').map_or((rest, None), |(body, name)| (body, Some(name)));
    let name = fragment.map(percent_decode).filter(|name| !name.is_empty()).unwrap_or_else(|| "ss".into());
    let (method, password, server, port) = if let Some((user, host)) = body.rsplit_once('@') {
        let decoded = base64_decode(user).and_then(|data| String::from_utf8(data).ok()).unwrap_or_else(|| percent_decode(user));
        let (method, password) = decoded.split_once(':').or_msg(malformed())?;
        let host = host.split('?').next().unwrap_or(host).trim_end_matches('/');
        let (server, port) = host.rsplit_once(':').or_msg(malformed())?;
        (method.to_string(), password.to_string(), server.to_string(), port.parse::<u16>().or_msg(malformed())?)
    } else {
        let decoded = base64_decode(body).map(|data| String::from_utf8_lossy(&data).into_owned()).or_msg(malformed())?;
        let pattern = regex::Regex::new(r"^([^:]+):([^@]+)@([^:]+):(\d+)").unwrap();
        let captures = pattern.captures(&decoded).or_msg(malformed())?;
        (captures[1].to_string(), captures[2].to_string(), captures[3].to_string(), captures[4].parse::<u16>().or_msg(malformed())?)
    };
    let mut proxy = Proxy::new();
    proxy.insert("name".into(), json!(name));
    proxy.insert("type".into(), json!("ss"));
    proxy.insert("server".into(), json!(server));
    proxy.insert("port".into(), json!(port));
    proxy.insert("cipher".into(), json!(method));
    proxy.insert("password".into(), json!(password));
    proxy.insert("udp".into(), json!(true));
    Ok(proxy)
}

pub fn parse_vmess(line: &str) -> Result<Proxy> {
    let malformed = || "malformed link".to_string();
    let body = line[8..].split('#').next().unwrap_or("");
    let data = base64_decode(body).or_msg(malformed())?;
    let Value::Object(fields) = parse_yaml(&String::from_utf8_lossy(&data)).or_msg(malformed())? else {
        return fail(malformed());
    };
    let text = |key: &str| match fields.get(key) {
        Some(Value::String(value)) => Some(value.clone()),
        Some(Value::Number(value)) => Some(value.to_string()),
        Some(Value::Bool(value)) => Some(value.to_string()),
        _ => None,
    };
    let server = text("add").or_msg(malformed())?;
    let port = text("port").and_then(|port| port.parse::<u16>().ok()).or_msg(malformed())?;
    let uuid = text("id").or_msg(malformed())?;
    let mut proxy = Proxy::new();
    proxy.insert("name".into(), json!(text("ps").filter(|name| !name.is_empty()).unwrap_or_else(|| "vmess".into())));
    proxy.insert("type".into(), json!("vmess"));
    proxy.insert("server".into(), json!(server));
    proxy.insert("port".into(), json!(port));
    proxy.insert("uuid".into(), json!(uuid));
    proxy.insert("alterId".into(), json!(text("aid").and_then(|aid| aid.parse::<i64>().ok()).unwrap_or(0)));
    proxy.insert("cipher".into(), json!(text("scy").filter(|cipher| !cipher.is_empty()).unwrap_or_else(|| "auto".into())));
    proxy.insert("udp".into(), json!(true));
    if matches!(text("tls").unwrap_or_default().to_lowercase().as_str(), "tls" | "true" | "1") {
        proxy.insert("tls".into(), json!(true));
    }
    if let Some(sni) = text("sni").filter(|sni| !sni.is_empty()) {
        proxy.insert("servername".into(), json!(sni));
    }
    if text("net").as_deref() == Some("ws") {
        proxy.insert("network".into(), json!("ws"));
        let mut options = Map::new();
        options.insert("path".into(), json!(text("path").unwrap_or_else(|| "/".into())));
        if let Some(host) = text("host").filter(|host| !host.is_empty()) {
            options.insert("headers".into(), json!({ "Host": host }));
        }
        proxy.insert("ws-opts".into(), Value::Object(options));
    }
    Ok(proxy)
}

/// Parser for a share-link scheme (vless, trojan, ss, vmess).
pub fn link_parser(scheme: &str) -> Option<fn(&str) -> Result<Proxy>> {
    match scheme {
        "vless" => Some(parse_vless),
        "trojan" => Some(parse_trojan),
        "ss" => Some(parse_shadowsocks),
        "vmess" => Some(parse_vmess),
        _ => None,
    }
}

const SCHEMES: [&str; 6] = ["vless://", "trojan://", "vmess://", "ss://", "hysteria2://", "tuic://"];

fn non_empty_lines(text: &str) -> Vec<String> {
    text.lines().map(str::trim).filter(|line| !line.is_empty()).map(str::to_string).collect()
}

fn has_links(lines: &[String]) -> bool {
    lines.iter().any(|line| SCHEMES.iter().any(|scheme| line.starts_with(scheme)))
}

fn decode_text(value: &str) -> Option<String> {
    let compact: String = value.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.is_empty() || !compact.chars().all(|c| c.is_ascii_alphanumeric() || "+/=_-".contains(c)) {
        return None;
    }
    base64_decode(&compact).and_then(|data| String::from_utf8(data).ok())
}

/// Returns the link lines and a description of the original form.
pub fn decode_links(text: &str) -> Result<(Vec<String>, String)> {
    if has_links(&non_empty_lines(text)) {
        return Ok((non_empty_lines(text), t("明文链接", "Plain links")));
    }
    let whole = decode_text(text).unwrap_or_default();
    if !SCHEMES.iter().any(|scheme| whole.contains(scheme)) {
        // Some subscriptions are one base64 value per line.
        let decoded: Vec<String> = non_empty_lines(text).iter().filter_map(|line| decode_text(line)).map(|line| line.trim().to_string()).collect();
        if SCHEMES.iter().any(|scheme| decoded.concat().contains(scheme)) {
            return Ok((decoded, t("逐行 base64", "Line-by-line base64")));
        }
    }
    if !has_links(&non_empty_lines(&whole)) {
        return fail(t("返回内容不是有效的 Clash 配置或节点链接订阅，请检查地址是否返回网页或错误信息。", "The response is not a valid Clash config or link subscription. Check whether the URL returns a web page or an error."));
    }
    Ok((non_empty_lines(&whole), t("整块 base64", "Base64 block")))
}

/// Parses subscription bytes into validated nodes, the detected form and per-line failures.
pub fn parse_subscription(data: &[u8]) -> Result<(Vec<Proxy>, String, Vec<String>)> {
    if data.is_empty() || data.len() > 16 * 1024 * 1024 {
        return fail(t("订阅为空或超过 16 MB 限制。", "The subscription is empty or over the 16 MB limit."));
    }
    let raw = String::from_utf8_lossy(data);
    let text = raw.trim_start_matches('\u{FEFF}').trim();
    let clash = regex::Regex::new(r#"(?m)^["']?proxies["']?\s*:"#).unwrap();
    if text.starts_with(['{', '[']) || clash.is_match(text) {
        let form = if text.starts_with(['{', '[']) { "Clash JSON" } else { "Clash YAML" };
        let Value::Object(document) = load_yaml(text)? else {
            return fail(t("Clash 订阅必须包含 proxies 节点列表。", "A Clash subscription must include a proxies list."));
        };
        // Only nodes are imported; the user's routing, DNS, ports and groups stay as they are.
        return Ok((validate_proxies(document.get("proxies"))?, form.to_string(), Vec::new()));
    }
    let (lines, form) = decode_links(text)?;
    let mut proxies = Vec::new();
    let mut failures = Vec::new();
    for (offset, line) in lines.iter().enumerate() {
        if line.starts_with('#') {
            continue;
        }
        let index = offset + 1;
        let scheme = line.split_once("://").map(|(scheme, _)| scheme.to_lowercase()).unwrap_or_default();
        match link_parser(&scheme) {
            None => failures.push(t(&format!("第 {index} 行：不支持的节点协议"), &format!("Line {index}: unsupported protocol"))),
            Some(parser) => match parser(line) {
                Ok(proxy) => proxies.push(Value::Object(proxy)),
                Err(_) => failures.push(t(&format!("第 {index} 行：节点链接格式不正确"), &format!("Line {index}: malformed node link"))),
            },
        }
    }
    Ok((validate_proxies(Some(&Value::Array(proxies)))?, form, failures))
}

pub fn parse_subscription_file(path: &Path) -> Result<Vec<Proxy>> {
    let data = std::fs::read(path).or_msg(t("无法读取节点文件。", "Could not read the node file."))?;
    Ok(parse_subscription(&data)?.0)
}

pub fn proxies_yaml(proxies: &[Proxy]) -> String {
    let mut document = Map::new();
    document.insert("proxies".into(), Value::Array(proxies.iter().cloned().map(Value::Object).collect()));
    to_yaml(&document, 0) + "\n"
}

/// Runs `mihomo -t` on a config holding only these nodes (no provider DNS, rules or scripts run).
pub fn check_nodes_with_core(directory: &Path, proxies: &[Proxy]) -> Result<()> {
    let binary = directory.join(crate::paths::CORE_BINARY);
    if !binary.is_file() {
        return fail(t("缺少 mihomo 内核，无法检查节点配置。", "The mihomo core is missing, so the node config cannot be checked."));
    }
    let work = support::temp_dir(".node-validate-", Some(directory))?;
    let candidate = work.path().join("validate.yaml");
    let config = json!({
        "mixed-port": 0, "mode": "rule", "allow-lan": false, "dns": {"enable": false},
        "proxies": proxies.iter().cloned().map(Value::Object).collect::<Vec<_>>(), "rules": ["MATCH,DIRECT"]
    });
    atomic_write(&candidate, (to_yaml(config.as_object().unwrap(), 0) + "\n").as_bytes())?;
    let directory_text = directory.to_string_lossy();
    let candidate_text = candidate.to_string_lossy();
    let result = support::run(&binary, &["-t", "-d", &directory_text, "-f", &candidate_text], Duration::from_secs(15));
    if result.timed_out || result.status.is_none() {
        return fail(t("节点配置检查失败或超时，本次未保存。", "Node config check failed or timed out; nothing was saved."));
    }
    if !result.success() {
        return fail(t("节点配置未通过内核检查，请检查节点协议、端口或认证参数。", "The node config failed the core check. Check the protocol, port or credentials."));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Update transaction

type Step<A, R> = Box<dyn FnMut(A) -> Result<R>>;

pub struct SubscriptionManager {
    pub directory: PathBuf,
    /// Replaceable steps, so tests can simulate the network, the service and the core.
    pub fetch: Step<String, Vec<Proxy>>,
    pub control: Step<&'static str, ()>,
    pub running: Box<dyn FnMut() -> bool>,
    pub verify: Step<Vec<Proxy>, ()>,
}

impl SubscriptionManager {
    pub fn new(directory: &Path) -> SubscriptionManager {
        let (a, b, c, d) = (directory.to_path_buf(), directory.to_path_buf(), directory.to_path_buf(), directory.to_path_buf());
        SubscriptionManager {
            directory: directory.to_path_buf(),
            fetch: Box::new(move |url| download(&a, &url)),
            control: Box::new(move |action| run_control(&b, action)),
            running: Box::new(move || support::core_running(&c)),
            verify: Box::new(move |proxies| verify_loaded(&d, &proxies)),
        }
    }

    pub fn url_file(&self) -> PathBuf {
        self.directory.join(".sub-url")
    }
    pub fn nodes_file(&self) -> PathBuf {
        self.directory.join("providers/nodes.yaml")
    }
    pub fn base_file(&self) -> PathBuf {
        self.directory.join("providers/subscription.yaml")
    }
    pub fn runtime_file(&self) -> PathBuf {
        self.directory.join(".run-config.yaml")
    }

    pub fn execute(&mut self, operation: &str, explicit_url: Option<&str>) -> Result<()> {
        let url = match explicit_url {
            Some(url) => url.to_string(),
            None => read_text(&self.url_file()).map(|text| text.trim().to_string()).or_msg(t("尚未设置订阅地址。", "No subscription URL set yet."))?,
        };
        let mut proxies = (self.fetch)(url.clone())?;
        if operation == "test" {
            say(&t("✓ 订阅测试通过；订阅地址、节点和代理状态均未修改", "✓ Subscription test passed; the URL, nodes and proxy state were not changed"));
            return Ok(());
        }
        // The subscription is kept as downloaded; manual nodes and edits are merged before the core sees them.
        let base = proxies_yaml(&proxies);
        proxies = crate::node_manager::merge_custom_nodes(&self.directory, proxies);
        let nodes = proxies_yaml(&proxies);
        let chain_changes = crate::chain::subscription_updates(&self.directory, &proxies)?;
        if operation == "fetch" {
            atomic_write(&self.base_file(), base.as_bytes())?;
            atomic_write(&self.nodes_file(), nodes.as_bytes())?;
            for (path, content) in &chain_changes {
                atomic_write(path, content)?;
            }
            return Ok(());
        }
        let was_running = (self.running)();
        let mut paths = vec![self.url_file(), self.base_file(), self.nodes_file(), self.runtime_file()];
        for path in chain_changes.keys() {
            if !paths.contains(path) {
                paths.push(path.clone());
            }
        }
        let saved = snapshot(&paths);
        let mut stopped = false;
        let mut start_attempted = false;
        let attempt = (|| -> Result<()> {
            if was_running {
                (self.control)("stop")?;
                stopped = true;
            }
            atomic_write(&self.base_file(), base.as_bytes())?;
            atomic_write(&self.nodes_file(), nodes.as_bytes())?;
            atomic_write(&self.url_file(), url.as_bytes())?;
            for (path, content) in &chain_changes {
                atomic_write(path, content)?;
            }
            start_attempted = true;
            (self.control)("start")?;
            (self.verify)(proxies.clone())
        })();
        if attempt.is_err() {
            let mut failures = Vec::new();
            if start_attempted && (self.control)("stop").is_err() {
                failures.push(t("停止新服务", "stopping the new service"));
            }
            if restore(&saved).is_err() {
                failures.push(t("恢复配置文件", "restoring config files"));
            }
            if was_running && stopped && (self.control)("start").is_err() {
                failures.push(t("恢复原服务", "restoring the previous service"));
            }
            if !failures.is_empty() {
                return fail(t(
                    &format!("更新失败，自动恢复未完成：{}。", failures.join("、")),
                    &format!("Update failed and automatic recovery was incomplete: {}.", failures.join(", ")),
                ));
            }
            return fail(t("订阅更新未生效，已恢复原订阅与节点，请检查代理配置或端口占用。", "The subscription update did not take effect; the previous subscription and nodes were restored. Check the proxy config or port conflicts."));
        }
        say(&t("✓ 订阅已保存，新节点已生效", "✓ Subscription saved; new nodes are active"));
        Ok(())
    }
}

fn download(directory: &Path, url: &str) -> Result<Vec<Proxy>> {
    let valid = url::Url::parse(url)
        .ok()
        .filter(|parsed| matches!(parsed.scheme(), "http" | "https") && parsed.host_str().is_some_and(|host| !host.is_empty()) && parsed.port() != Some(0))
        .is_some();
    if !valid || url.chars().any(char::is_whitespace) {
        return fail(t("请输入有效的 http:// 或 https:// 订阅地址。", "Enter a valid http:// or https:// subscription URL."));
    }
    let work = support::temp_dir(".sub-stage-", Some(directory))?;
    let raw = work.path().join("response");
    say(&t("→ 拉取订阅…", "→ Fetching subscription…"));
    let raw_text = raw.to_string_lossy();
    let limit = (16 * 1024 * 1024).to_string();
    let result = support::run(
        Path::new(crate::paths::CURL),
        &["-sS", "-L", "--proto", "=http,https", "--proto-redir", "=http,https", "--connect-timeout", "8", "--max-time", "30",
          "--max-filesize", &limit, "-A", "mihomo/1.19.32", "-o", &raw_text, "-w", "%{http_code}", url],
        Duration::from_secs(35),
    );
    if result.timed_out || result.status.is_none() {
        return fail(t("订阅下载失败或超时，请检查网络后重试。", "Subscription download failed or timed out. Check your network and try again."));
    }
    if let Some(code) = result.status.filter(|code| *code != 0) {
        return fail(t(&format!("订阅下载失败（curl {code}），请检查网络或服务器证书。"), &format!("Subscription download failed (curl {code}). Check your network or the server certificate.")));
    }
    let status = result.text().trim().to_string();
    if status != "200" {
        let shown = if status.is_empty() { t("未知", "unknown") } else { status };
        return fail(t(&format!("订阅服务器返回 HTTP {shown}。"), &format!("The subscription server returned HTTP {shown}.")));
    }
    let (proxies, form, failures) = parse_subscription(&std::fs::read(&raw).unwrap_or_default())?;
    say(&t(&format!("✓ {form}，解析出 {} 个节点", proxies.len()), &format!("✓ {form}: parsed {} nodes", proxies.len())));
    if !failures.is_empty() {
        say(&t(&format!("! 跳过 {} 条不支持或无效的链接", failures.len()), &format!("! Skipped {} unsupported or invalid links", failures.len())));
    }
    check_nodes_with_core(directory, &proxies)?;
    say(&t("✓ 内核节点检查通过", "✓ Core node check passed"));
    Ok(proxies)
}

fn run_control(directory: &Path, action: &str) -> Result<()> {
    let script = directory.join("mihomoctl.sh");
    let script_text = script.to_string_lossy();
    let result = support::run(Path::new("/bin/bash"), &[&script_text, action], Duration::from_secs(20));
    if result.timed_out || result.status.is_none() {
        return fail(t("代理服务操作超时或失败。", "The proxy service operation timed out or failed."));
    }
    if !result.success() {
        return fail(t("代理服务启动失败，请检查端口占用或当前配置。", "The proxy service failed to start. Check for port conflicts or the current config."));
    }
    Ok(())
}

fn verify_loaded(directory: &Path, proxies: &[Proxy]) -> Result<()> {
    let expected: HashSet<&str> = proxies.iter().map(name_of).collect();
    let secret = support::api_secret(directory);
    let authorization = format!("Bearer {secret}");
    let headers: Vec<(&str, &str)> = if secret.is_empty() { vec![] } else { vec![("Authorization", authorization.as_str())] };
    for _ in 0..3 {
        let url = format!("http://{}/providers/proxies/nodes", support::api_address());
        if let Ok(response) = support::http("GET", &url, &headers, None, Duration::from_secs(4)) {
            if let Some(loaded) = response.json().and_then(|value| value.get("proxies").and_then(Value::as_array).cloned()) {
                let names: HashSet<&str> = loaded.iter().filter_map(|proxy| proxy.get("name").and_then(Value::as_str)).collect();
                if loaded.len() == proxies.len() && names == expected {
                    say(&t(&format!("✓ 内核已加载 {} 个节点", proxies.len()), &format!("✓ Core loaded {} nodes", proxies.len())));
                    return Ok(());
                }
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(Error(t("内核未能加载完整节点列表。", "The core did not load the full node list.")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    fn node() -> Proxy {
        json!({"name": "测试 \"节点\"", "type": "trojan", "server": "node.example", "port": 443,
               "password": "test-credential", "tls": true, "udp": true, "alpn": ["h2", "http/1.1"]})
        .as_object()
        .unwrap()
        .clone()
    }

    const YAML: &str = "proxies:\n  - name: 测试节点\n    type: trojan\n    server: node.example\n    port: 443\n    password: test-credential\n    tls: true\n    udp: true\n    alpn: [h2, http/1.1]\nproxy-groups:\n  - name: remote-group\n    type: select\n    proxies: [测试节点]\nrules:\n  - MATCH,remote-group\n";

    #[test]
    fn clash_yaml_preserves_types_and_node_options() {
        let (nodes, form, failures) = parse_subscription(YAML.as_bytes()).unwrap();
        assert_eq!(form, "Clash YAML");
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0]["tls"], true);
        assert_eq!(nodes[0]["port"], 443);
        assert_eq!(nodes[0]["alpn"], json!(["h2", "http/1.1"]));
        assert!(failures.is_empty());
        let output = parse_yaml(&proxies_yaml(&nodes)).unwrap();
        assert_eq!(output.as_object().unwrap().keys().collect::<Vec<_>>(), ["proxies"]);
    }

    #[test]
    fn json_and_flow_yaml() {
        let text = json!({"proxies": [node()]}).to_string();
        assert_eq!(parse_subscription(text.as_bytes()).unwrap().0, vec![node()]);
        let flow = "proxies: [{name: test, type: trojan, server: node.example, port: 443, password: fake}]";
        assert_eq!(parse_subscription(flow.as_bytes()).unwrap().0[0]["port"], 443);
    }

    #[test]
    fn plain_and_base64_links() {
        let line = "trojan://fake-password@node.example:443?sni=node.example#sample";
        let encoded = base64::engine::general_purpose::STANDARD.encode(line).trim_end_matches('=').to_string();
        for text in [line.to_string(), encoded] {
            assert_eq!(parse_subscription(text.as_bytes()).unwrap().0[0]["type"], "trojan");
        }
    }

    #[test]
    fn line_by_line_base64() {
        let lines = ["trojan://first@a.example:443#first", "trojan://second@b.example:443#second"];
        let text: Vec<String> = lines.iter().map(|line| base64::engine::general_purpose::STANDARD.encode(line)).collect();
        assert_eq!(parse_subscription(text.join("\n").as_bytes()).unwrap().0.len(), 2);
    }

    #[test]
    fn empty_html_and_empty_proxies_fail() {
        for text in ["", "<html>sign in</html>", "proxies: []", "{\"rules\": []}"] {
            assert!(parse_subscription(text.as_bytes()).is_err(), "{text}");
        }
    }

    #[test]
    fn duplicate_invalid_ports_and_cycles_fail() {
        let mut boolean_port = node();
        boolean_port.insert("port".into(), json!(true));
        let mut large_port = node();
        large_port.insert("port".into(), json!(99999));
        for proxies in [vec![node(), node()], vec![boolean_port], vec![large_port]] {
            assert!(parse_subscription(json!({ "proxies": proxies }).to_string().as_bytes()).is_err());
        }
        assert!(parse_subscription(b"proxies: &loop [*loop]").is_err());
        assert!(load_yaml("!!python/object/apply:builtins.str [unsafe]").is_err());
    }

    #[test]
    fn share_links_parse_like_before() {
        let vless = parse_vless("vless://uuid-1@[2001:db8::1]:443?type=ws&path=%2Fws&host=cdn.example&security=tls&sni=s.example&alpn=h2,http/1.1&sid=#%F0%9F%87%AF%F0%9F%87%B5%20Tokyo").unwrap();
        assert_eq!(vless["name"], "🇯🇵 Tokyo");
        assert_eq!(vless["server"], "2001:db8::1");
        assert_eq!(vless["ws-opts"], json!({"path": "/ws", "headers": {"Host": "cdn.example"}}));
        assert_eq!(vless["servername"], "s.example");
        assert_eq!(vless["alpn"], json!(["h2", "http/1.1"]));
        let reality = parse_vless("vless://u@h.example:443?security=reality&pbk=KEY&sid=ab&sni=www.example&flow=xtls-rprx-vision").unwrap();
        assert_eq!(reality["reality-opts"], json!({"public-key": "KEY", "short-id": "ab"}));
        assert_eq!(reality["flow"], "xtls-rprx-vision");
        let ss = parse_shadowsocks("ss://YWVzLTI1Ni1nY206ZmFrZQ@1.2.3.4:8388#my-ss").unwrap();
        assert_eq!((ss["cipher"].as_str(), ss["password"].as_str(), ss["port"].as_i64()), (Some("aes-256-gcm"), Some("fake"), Some(8388)));
        let legacy = base64::engine::general_purpose::STANDARD.encode("chacha20-ietf-poly1305:pw@5.6.7.8:443");
        assert_eq!(parse_shadowsocks(&format!("ss://{legacy}#old")).unwrap()["server"], "5.6.7.8");
        let vmess_json = json!({"ps": "vm", "add": "v.example", "port": "443", "id": "abc", "aid": 0, "net": "ws", "path": "/v", "tls": "tls"});
        let vmess = parse_vmess(&format!("vmess://{}", base64::engine::general_purpose::STANDARD.encode(vmess_json.to_string()))).unwrap();
        assert_eq!((vmess["port"].as_i64(), vmess["tls"].as_bool(), vmess["ws-opts"]["path"].as_str()), (Some(443), Some(true), Some("/v")));
        let trojan = parse_trojan("trojan://p%40ss@t.example:443?peer=peer.example&allowInsecure=1").unwrap();
        assert_eq!((trojan["password"].as_str(), trojan["sni"].as_str(), trojan["skip-cert-verify"].as_bool()), (Some("p@ss"), Some("peer.example"), Some(true)));
    }

    struct Fixture {
        _directory: tempfile::TempDir,
        manager: SubscriptionManager,
        calls: Rc<RefCell<Vec<&'static str>>>,
    }

    fn fixture(fetch_result: Result<Vec<Proxy>>, running: bool) -> Fixture {
        let directory = tempfile::tempdir().unwrap();
        let mut manager = SubscriptionManager::new(directory.path());
        std::fs::write(manager.url_file(), "https://old.example/sub").unwrap();
        std::fs::create_dir_all(directory.path().join("providers")).unwrap();
        std::fs::write(manager.nodes_file(), "old nodes").unwrap();
        std::fs::write(manager.runtime_file(), "old runtime").unwrap();
        let calls = Rc::new(RefCell::new(Vec::new()));
        manager.fetch = Box::new(move |_| fetch_result.clone());
        manager.running = Box::new(move || running);
        let recorded = calls.clone();
        manager.control = Box::new(move |action| {
            recorded.borrow_mut().push(action);
            Ok(())
        });
        manager.verify = Box::new(|_| Ok(()));
        Fixture { _directory: directory, manager, calls }
    }

    fn contents(manager: &SubscriptionManager) -> Vec<Option<Vec<u8>>> {
        [manager.url_file(), manager.nodes_file(), manager.runtime_file()].iter().map(|path| std::fs::read(path).ok()).collect()
    }

    #[test]
    fn test_only_changes_nothing() {
        let mut fixture = fixture(Ok(vec![node()]), false);
        let before = contents(&fixture.manager);
        fixture.manager.execute("test", Some("https://new.example/sub")).unwrap();
        assert!(fixture.calls.borrow().is_empty());
        assert_eq!(contents(&fixture.manager), before);
    }

    #[test]
    fn fetch_failure_preserves_files_and_service() {
        let mut fixture = fixture(Err(Error("invalid YAML".into())), true);
        let before = contents(&fixture.manager);
        assert!(fixture.manager.execute("save", Some("https://new.example/sub")).is_err());
        assert!(fixture.calls.borrow().is_empty());
        assert_eq!(contents(&fixture.manager), before);
    }

    #[test]
    fn save_commits_and_verifies_loaded_nodes() {
        let mut fixture = fixture(Ok(vec![node()]), false);
        fixture.manager.execute("save", Some("https://new.example/sub")).unwrap();
        assert_eq!(*fixture.calls.borrow(), ["start"]);
        assert_eq!(std::fs::read_to_string(fixture.manager.url_file()).unwrap(), "https://new.example/sub");
        let saved = parse_yaml(&std::fs::read_to_string(fixture.manager.nodes_file()).unwrap()).unwrap();
        assert_eq!(saved["proxies"], json!([node()]));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(fixture.manager.nodes_file()).unwrap().permissions().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn failed_start_restores_url_nodes_and_runtime() {
        let mut fixture = fixture(Ok(vec![node()]), false);
        let before = contents(&fixture.manager);
        let runtime = fixture.manager.runtime_file();
        fixture.manager.control = Box::new(move |action| {
            if action == "start" {
                std::fs::write(&runtime, "new runtime").unwrap();
                return Err(Error("startup failure".into()));
            }
            Ok(())
        });
        assert!(fixture.manager.execute("save", Some("https://new.example/sub")).is_err());
        assert_eq!(contents(&fixture.manager), before);
    }

    #[test]
    fn verification_failure_restarts_original_service() {
        let mut fixture = fixture(Ok(vec![node()]), true);
        let before = contents(&fixture.manager);
        fixture.manager.verify = Box::new(|_| Err(Error("not loaded".into())));
        assert!(fixture.manager.execute("save", Some("https://new.example/sub")).is_err());
        assert_eq!(contents(&fixture.manager), before);
        assert_eq!(*fixture.calls.borrow(), ["stop", "start", "stop", "start"]);
    }
}
