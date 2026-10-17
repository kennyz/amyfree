//! Reads only the validity period of a node's TLS certificate; sends no proxy credentials and
//! never changes the node's own verification options.

use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme};
use serde_json::{json, Map, Value};

use crate::chain::{read_state, EXIT};
use crate::subscription::{name_of, parse_subscription_file, Proxy};
use crate::support::{t, Result};

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|value| value.as_secs_f64()).unwrap_or(0.0)
}

pub fn classify_dates(not_before: f64, not_after: f64, now: f64, trusted: bool) -> Map<String, Value> {
    if not_after <= not_before {
        return json!({"state": "unknown", "reason": t("证书日期无法解析", "Could not parse certificate dates")}).as_object().unwrap().clone();
    }
    let days = ((not_after - now) / 86400.0).ceil() as i64;
    let state = if now < not_before {
        "not_yet_valid"
    } else if now >= not_after {
        "expired"
    } else if !trusted {
        "untrusted"
    } else if not_after - now <= 30.0 * 86400.0 {
        "expiring"
    } else {
        "valid"
    };
    json!({"state": state, "not_before": not_before, "not_after": not_after, "days_left": days, "trusted": trusted, "checked_at": now})
        .as_object()
        .unwrap()
        .clone()
}

#[derive(Debug, PartialEq)]
pub enum Target {
    Endpoint { host: String, port: u16, server_name: String },
    Skip(Map<String, Value>),
}

fn skip(state: &str, reason: String) -> Target {
    Target::Skip(json!({"state": state, "reason": reason}).as_object().unwrap().clone())
}

fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64() != Some(0.0),
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::Object(map)) => !map.is_empty(),
    }
}

pub fn tls_target(proxy: &Proxy) -> Target {
    let kind = proxy.get("type").and_then(Value::as_str).unwrap_or("").to_lowercase();
    if truthy(proxy.get("reality-opts")) {
        return skip("not_applicable", t("REALITY 不使用常规 CA 证书", "REALITY does not use regular CA certificates"));
    }
    if ["hysteria", "hysteria2", "tuic", "quic"].contains(&kind.as_str()) {
        return skip("unsupported", t("暂不支持 QUIC 证书检查", "QUIC certificate checks are not supported yet"));
    }
    if kind != "trojan" && !truthy(proxy.get("tls")) {
        return skip("not_applicable", t("此节点未使用 TLS", "This node does not use TLS"));
    }
    let host = proxy.get("server").and_then(Value::as_str).filter(|host| !host.is_empty());
    let port = proxy.get("port").and_then(Value::as_u64).and_then(|port| u16::try_from(port).ok());
    let (Some(host), Some(port)) = (host, port) else {
        return skip("unknown", t("缺少 TLS 服务器地址", "Missing TLS server address"));
    };
    let server_name = ["servername", "sni"]
        .iter()
        .filter_map(|key| proxy.get(*key).and_then(Value::as_str))
        .find(|name| !name.is_empty())
        .unwrap_or(host)
        .to_string();
    Target::Endpoint { host: host.to_string(), port, server_name }
}

/// Asks the operating system whether the chain is trusted for this name, records the answer and the
/// leaf certificate, then lets the handshake continue so the dates can be read. Diagnostic only.
#[derive(Debug)]
struct Recorder {
    inner: Arc<dyn ServerCertVerifier>,
    seen: Arc<Mutex<Option<(Vec<u8>, bool)>>>,
}

impl ServerCertVerifier for Recorder {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        let trusted = self.inner.verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now).is_ok();
        *self.seen.lock().unwrap() = Some((end_entity.to_vec(), trusted));
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(&self, _: &[u8], _: &CertificateDer<'_>, _: &DigitallySignedStruct) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(&self, _: &[u8], _: &CertificateDer<'_>, _: &DigitallySignedStruct) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.inner.supported_verify_schemes()
    }
}

/// Validity dates of a DER certificate, as Unix timestamps.
pub fn certificate_dates(der: &[u8]) -> Option<(f64, f64)> {
    let (_, certificate) = x509_parser::parse_x509_certificate(der).ok()?;
    let validity = certificate.validity();
    Some((validity.not_before.timestamp() as f64, validity.not_after.timestamp() as f64))
}

fn handshake(host: &str, port: u16, server_name: &str, alpn: Vec<Vec<u8>>, timeout: Duration) -> Option<(Vec<u8>, bool)> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let platform = rustls_platform_verifier::Verifier::new(provider.clone()).ok()?;
    let seen = Arc::new(Mutex::new(None));
    let recorder = Recorder { inner: Arc::new(platform), seen: seen.clone() };
    let mut config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .ok()?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(recorder))
        .with_no_client_auth();
    config.alpn_protocols = alpn;
    let name = ServerName::try_from(server_name.to_string()).ok()?;
    let mut connection = ClientConnection::new(Arc::new(config), name).ok()?;
    let address = (host, port).to_socket_addrs().ok()?.next()?;
    let mut socket = TcpStream::connect_timeout(&address, timeout).ok()?;
    socket.set_read_timeout(Some(timeout)).ok()?;
    socket.set_write_timeout(Some(timeout)).ok()?;
    let deadline = std::time::Instant::now() + timeout;
    while connection.is_handshaking() && seen.lock().unwrap().is_none() && std::time::Instant::now() < deadline {
        if connection.wants_write() && connection.write_tls(&mut socket).is_err() {
            break;
        }
        if connection.wants_read() {
            match connection.read_tls(&mut socket) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    if connection.process_new_packets().is_err() {
                        break;
                    }
                }
            }
        }
    }
    let result = seen.lock().unwrap().take();
    result
}

pub fn inspect_certificate(proxy: &Proxy, timeout: Duration) -> Map<String, Value> {
    let (host, port, server_name) = match tls_target(proxy) {
        Target::Skip(result) => return result,
        Target::Endpoint { host, port, server_name } => (host, port, server_name),
    };
    let failure = json!({"state": "unknown", "reason": t("无法读取服务器证书", "Could not read the server certificate"), "checked_at": now()})
        .as_object()
        .unwrap()
        .clone();
    let alpn = proxy
        .get("alpn")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(|value| value.as_bytes().to_vec()).collect())
        .unwrap_or_default();
    let Some((der, trusted)) = handshake(&host, port, &server_name, alpn, timeout) else { return failure };
    let Some((before, after)) = certificate_dates(&der) else { return failure };
    let mut result = classify_dates(before, after, now(), trusted);
    if !trusted {
        result.insert("reason".into(), json!(t("证书信任或域名校验未通过", "Certificate trust or hostname check failed")));
    }
    result
}

pub fn combine(certificates: &[Map<String, Value>]) -> Map<String, Value> {
    let rank = |state: &str| match state {
        "expired" => 0,
        "not_yet_valid" => 1,
        "untrusted" => 2,
        "expiring" => 4,
        "valid" => 5,
        "not_applicable" => 6,
        _ => 3,
    };
    let key = |item: &Map<String, Value>| {
        let state = item.get("state").and_then(Value::as_str).unwrap_or("");
        (rank(state), item.get("not_after").and_then(Value::as_f64).unwrap_or(f64::INFINITY))
    };
    let Some(selected) = certificates.iter().min_by(|a, b| key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal)) else {
        return json!({"state": "unknown", "reason": t("无法确认链路证书", "Could not confirm the chain certificates")}).as_object().unwrap().clone();
    };
    let mut result = selected.clone();
    result.insert("chain".into(), json!(true));
    let reason = result.get("reason").and_then(Value::as_str).filter(|reason| !reason.is_empty()).map(str::to_string);
    let summary = t("入口与出口中最需关注的证书", "The more urgent certificate of the entry and exit") + &reason.map(|reason| t("；", "; ") + &reason).unwrap_or_default();
    result.insert("reason".into(), json!(summary));
    result
}

/// Checks every node, three connections at a time.
pub fn certificate_batch(directory: &Path) -> Result<Map<String, Value>> {
    let proxies = parse_subscription_file(&directory.join("providers/nodes.yaml"))?;
    let values = crate::speed::parallel_map(&proxies, 3, |proxy| inspect_certificate(proxy, Duration::from_secs(3)));
    let mut result = Map::new();
    for (proxy, value) in proxies.iter().zip(values) {
        result.insert(name_of(proxy).to_string(), Value::Object(value));
    }
    let chain = read_state(directory)?;
    if chain.get("enabled").and_then(Value::as_bool) == Some(true) {
        let parts: Vec<Map<String, Value>> = ["entry", "exit"]
            .iter()
            .map(|key| {
                chain.get(*key).and_then(Value::as_str).and_then(|name| result.get(name)).and_then(Value::as_object).cloned()
                    .unwrap_or_else(|| json!({"state": "unknown"}).as_object().unwrap().clone())
            })
            .collect();
        result.insert(EXIT.to_string(), Value::Object(combine(&parts)));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn expiry_boundaries_and_untrusted_are_distinct() {
        let now = 2_000_000_000.0;
        let state = |before: f64, after: f64, trusted: bool| classify_dates(before, after, now, trusted)["state"].as_str().unwrap().to_string();
        assert_eq!(state(now - 100.0, now + 31.0 * 86400.0, true), "valid");
        assert_eq!(state(now - 100.0, now + 30.0 * 86400.0, true), "expiring");
        assert_eq!(state(now - 100.0, now, true), "expired");
        assert_eq!(state(now + 1.0, now + 86400.0, true), "not_yet_valid");
        assert_eq!(state(now - 100.0, now + 60.0 * 86400.0, false), "untrusted");
        assert_eq!(classify_dates(now - 100.0, now - 1.0, now, true)["days_left"], 0);
    }

    #[test]
    fn sni_and_special_protocols() {
        let node = object(json!({"type": "trojan", "server": "example.com", "port": 443, "sni": "tls.example"}));
        assert_eq!(tls_target(&node), Target::Endpoint { host: "example.com".into(), port: 443, server_name: "tls.example".into() });
        let mut override_name = node.clone();
        override_name.insert("servername".into(), json!("override.example"));
        assert!(matches!(tls_target(&override_name), Target::Endpoint { server_name, .. } if server_name == "override.example"));
        let state = |value: Value| match tls_target(&object(value)) { Target::Skip(result) => result["state"].as_str().unwrap().to_string(), _ => "endpoint".into() };
        assert_eq!(state(json!({"type": "vless", "tls": true, "reality-opts": {"public-key": "demo"}})), "not_applicable");
        assert_eq!(state(json!({"type": "ss"})), "not_applicable");
        assert_eq!(state(json!({"type": "tuic"})), "unsupported");
    }

    #[test]
    fn connection_failure_is_unknown_not_expired() {
        let port = crate::support::free_port();
        let value = inspect_certificate(&object(json!({"type": "trojan", "server": "127.0.0.1", "port": port})), Duration::from_millis(200));
        assert_eq!(value["state"], "unknown");
        assert!(!value.contains_key("not_after"));
    }

    #[test]
    fn chain_reports_worst_or_earliest_certificate() {
        let valid = object(json!({"state": "valid", "not_after": 9999999999.0}));
        let soon = object(json!({"state": "expiring", "not_after": 8888888888.0}));
        let expired = object(json!({"state": "expired", "not_after": 1111111111.0}));
        assert_eq!(combine(&[valid.clone(), soon.clone()])["state"], "expiring");
        assert_eq!(combine(&[soon, expired])["state"], "expired");
        assert_eq!(combine(&[valid, object(json!({"state": "unknown"}))])["state"], "unknown");
    }
}
