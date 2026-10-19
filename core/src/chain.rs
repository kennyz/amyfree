//! Two-hop chain proxy: updates only the managed nodes and policy groups, keeping the rest of the config.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Map, Value};

use crate::subscription::{load_yaml, name_of, parse_subscription_file, type_of, Proxy};
use crate::support::{self, atomic_write, fail, read_text, restore, snapshot, t, Error, Result};
use crate::yaml::{json_text, to_yaml};

pub const ENTRY: &str = "MIMIO_CHAIN_ENTRY";
pub const EXIT: &str = "MIMIO_CHAIN_EXIT";
const GROUPS: [&str; 2] = ["PROXY", "手动选择"];

fn chain_dns() -> Value {
    json!(["https://dns.alidns.com/dns-query"])
}

pub fn read_state(directory: &Path) -> Result<Map<String, Value>> {
    let Some(text) = read_text(&directory.join(".mimio-chain.json")) else {
        return Ok(json!({"enabled": false, "entry": "", "exit": ""}).as_object().unwrap().clone());
    };
    match load_yaml(&text)? {
        Value::Object(state) => Ok(state),
        _ => fail(t("无法读取链式配置。", "Could not read the chain config.")),
    }
}

fn text<'a>(map: &'a Map<String, Value>, key: &str) -> &'a str {
    map.get(key).and_then(Value::as_str).unwrap_or("")
}

fn flag(map: &Map<String, Value>, key: &str) -> bool {
    map.get(key).and_then(Value::as_bool) == Some(true)
}

pub fn chain_nodes(proxies: &[Proxy], entry: &str, exit: &str) -> Result<Vec<Proxy>> {
    if entry == exit {
        return fail(t("入口和出口请选择不同的节点。", "Choose different entry and exit nodes."));
    }
    let find = |name: &str| proxies.iter().find(|proxy| name_of(proxy) == name).cloned();
    let (Some(mut first), Some(mut last)) = (find(entry), find(exit)) else {
        return fail(t("入口或出口已不在订阅中，请重新选择。", "The entry or exit node is no longer in the subscription. Choose again."));
    };
    if [&first, &last].iter().any(|proxy| matches!(type_of(proxy), "direct" | "reject")) {
        return fail(t("请选择两个实际代理节点作为入口和出口。", "Choose two real proxy nodes as the entry and exit."));
    }
    if proxies.iter().any(|proxy| [ENTRY, EXIT].contains(&name_of(proxy))) {
        return fail(t("节点名称与链式代理保留名称冲突。", "A node name conflicts with a name reserved for chain proxy."));
    }
    first.insert("name".into(), json!(ENTRY));
    first.remove("dialer-proxy");
    last.insert("name".into(), json!(EXIT));
    last.insert("dialer-proxy".into(), json!(ENTRY));
    Ok(vec![first, last])
}

fn is_header(line: &str, key: Option<&str>) -> bool {
    let name_end = line.find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-')).unwrap_or(line.len());
    if name_end == 0 || !line[name_end..].trim_start().starts_with(':') {
        return false;
    }
    key.is_none_or(|key| &line[..name_end] == key)
}

/// Replaces (or removes, for None) one top-level block in the config text, keeping everything else verbatim.
pub fn replace_block(source: &str, key: &str, value: Option<Value>) -> Result<String> {
    let lines: Vec<&str> = source.split_inclusive('\n').collect();
    let starts: Vec<usize> = (0..lines.len()).filter(|&index| is_header(lines[index], Some(key))).collect();
    if starts.len() > 1 {
        return fail(t("配置存在重复字段，暂不能修改链式代理。", "The config has duplicate fields, so chain proxy cannot be changed."));
    }
    let replacement = match value {
        Some(value) => {
            let mut block = Map::new();
            block.insert(key.to_string(), value);
            to_yaml(&block, 0) + "\n"
        }
        None => String::new(),
    };
    let Some(&start) = starts.first() else {
        let separator = if !source.is_empty() && !source.ends_with('\n') { "\n" } else { "" };
        return Ok(format!("{source}{separator}{replacement}"));
    };
    let mut end = start + 1;
    while end < lines.len() && !is_header(lines[end], None) {
        end += 1;
    }
    // Keep blank lines and top-level comments that precede the next section.
    while end > start + 1 && (lines[end - 1].trim().is_empty() || lines[end - 1].starts_with('#')) {
        end -= 1;
    }
    Ok(format!("{}{}{}", lines[..start].concat(), replacement, lines[end..].concat()))
}

fn chain_group(name: &str) -> Value {
    json!({"name": name, "type": "select", "proxies": [EXIT]})
}

pub fn render(source: &str, proxies: &[Proxy], previous: &Map<String, Value>, enabled: bool, entry: &str, exit: &str) -> Result<(String, Map<String, Value>)> {
    let Value::Object(data) = load_yaml(source)? else {
        return fail(t("无法读取配置。", "Could not read the config."));
    };
    let list = |key: &str| match data.get(key) {
        None | Some(Value::Null) => Some(Vec::new()),
        Some(Value::Array(items)) => Some(items.clone()),
        _ => None,
    };
    let (Some(mut existing), Some(mut groups)) = (list("proxies"), list("proxy-groups")) else {
        return fail(t("当前代理组配置格式暂不支持链式设置。", "The current proxy group format does not support chain settings."));
    };
    let was_enabled = flag(previous, "enabled");
    let managed = |value: &Value| [ENTRY, EXIT].contains(&value.get("name").and_then(Value::as_str).unwrap_or(""));
    if !was_enabled && existing.iter().any(managed) {
        return fail(t("当前配置已有同名保留节点，请先更名。", "The config already has a node with a reserved name. Rename it first."));
    }
    let group_name = |group: &Value| group.get("name").and_then(Value::as_str).unwrap_or("").to_string();
    if was_enabled {
        for group in &groups {
            let name = group_name(group);
            if GROUPS.contains(&name.as_str()) && *group != chain_group(&name) {
                return fail(t("链式代理组已被手工修改，请先恢复代理组设置。", "The chain proxy group was edited by hand. Restore the proxy group settings first."));
            }
        }
    }
    existing.retain(|value| !managed(value));
    let original: Vec<Value> = if was_enabled {
        previous.get("original_groups").and_then(Value::as_array).cloned().unwrap_or_default()
    } else {
        groups.iter().filter(|group| GROUPS.contains(&group_name(group).as_str())).cloned().collect()
    };
    if enabled {
        if !original.iter().any(|group| group_name(group) == "PROXY") {
            return fail(t("当前配置缺少 PROXY 代理组。", "The config is missing the PROXY group."));
        }
        existing.extend(chain_nodes(proxies, entry, exit)?.into_iter().map(Value::Object));
        groups = groups
            .into_iter()
            .map(|group| if GROUPS.contains(&group_name(&group).as_str()) { chain_group(&group_name(&group)) } else { group })
            .collect();
    } else if was_enabled {
        groups = groups
            .into_iter()
            .map(|group| original.iter().find(|saved| group_name(saved) == group_name(&group)).cloned().unwrap_or(group))
            .collect();
    }
    let mut updated = replace_block(source, "proxies", if existing.is_empty() { None } else { Some(Value::Array(existing)) })?;
    updated = replace_block(&updated, "proxy-groups", Some(Value::Array(groups)))?;
    let mut state = json!({"enabled": enabled, "entry": entry, "exit": exit}).as_object().unwrap().clone();
    let mut dns = data.get("dns").and_then(Value::as_object).cloned().unwrap_or_default();
    if enabled {
        state.insert("original_groups".into(), Value::Array(original));
        for key in ["enable", "proxy-server-nameserver"] {
            let saved_key = format!("original_dns_{key}");
            let saved = if was_enabled {
                previous.get(&saved_key).cloned().unwrap_or(Value::Null)
            } else {
                json!({"exists": dns.contains_key(key), "value": dns.get(key).cloned().unwrap_or(Value::Null)})
            };
            state.insert(saved_key, saved);
        }
        // Only node server addresses switch resolvers, so the remote entry never receives a fake IP;
        // website and LAN DNS rules stay as they are.
        dns.insert("enable".into(), json!(true));
        dns.insert("proxy-server-nameserver".into(), chain_dns());
        updated = replace_block(&updated, "dns", Some(Value::Object(dns)))?;
    } else if was_enabled {
        for (key, managed_value) in [("enable", json!(true)), ("proxy-server-nameserver", chain_dns())] {
            if let Some(saved) = previous.get(&format!("original_dns_{key}")).and_then(Value::as_object) {
                if dns.get(key) == Some(&managed_value) {
                    if saved.get("exists").and_then(Value::as_bool) == Some(true) {
                        dns.insert(key.into(), saved.get("value").cloned().unwrap_or(Value::Null));
                    } else {
                        dns.remove(key);
                    }
                }
            }
        }
        updated = replace_block(&updated, "dns", if dns.is_empty() { None } else { Some(Value::Object(dns)) })?;
    }
    Ok((updated, state))
}

/// On subscription refresh: sync chain node credentials; turn the chain off if the entry or exit is gone.
pub fn subscription_updates(directory: &Path, proxies: &[Proxy]) -> Result<BTreeMap<PathBuf, Vec<u8>>> {
    let previous = read_state(directory)?;
    if !flag(&previous, "enabled") {
        return Ok(BTreeMap::new());
    }
    let (entry, exit) = (text(&previous, "entry").to_string(), text(&previous, "exit").to_string());
    let enabled = proxies.iter().any(|proxy| name_of(proxy) == entry) && proxies.iter().any(|proxy| name_of(proxy) == exit);
    let source = read_text(&directory.join("config.yaml")).unwrap_or_default();
    let (updated, state) = render(&source, proxies, &previous, enabled, &entry, &exit)?;
    let secret = support::api_secret(directory);
    let mut result = BTreeMap::new();
    result.insert(directory.join("config.yaml"), updated.clone().into_bytes());
    result.insert(directory.join(".run-config.yaml"), updated.replace("__API_SECRET__", &secret).into_bytes());
    result.insert(directory.join(".mimio-chain.json"), json_text(&Value::Object(state)).into_bytes());
    let notun = directory.join(".config.yaml.notun");
    if let Some(text) = read_text(&notun) {
        result.insert(notun, render(&text, proxies, &previous, enabled, &entry, &exit)?.0.into_bytes());
    }
    Ok(result)
}

pub fn reload_runtime(directory: &Path, path: &Path, expected: &Map<String, Value>) -> Result<()> {
    let authorization = format!("Bearer {}", support::api_secret(directory));
    let headers = [("Authorization", authorization.as_str()), ("Content-Type", "application/json")];
    let api = support::api_address();
    let body = json_text(&json!({ "path": path.to_string_lossy() }));
    let reload = support::http("PUT", &format!("http://{api}/configs?force=true"), &headers, Some(body.as_bytes()), Duration::from_secs(12))?;
    if !(200..300).contains(&reload.status) {
        return fail("reload failed".into());
    }
    let group = support::http("GET", &format!("http://{api}/proxies/PROXY"), &headers, None, Duration::from_secs(5))?;
    let now = group.json().and_then(|value| value.get("now").and_then(Value::as_str).map(str::to_string));
    if flag(expected, "enabled") && now.as_deref() != Some(EXIT) {
        return fail(t("内核未采用链式出口。", "The core did not switch to the chain exit."));
    }
    if !flag(expected, "enabled") && now.as_deref() == Some(EXIT) {
        return fail(t("内核尚未退出链式代理。", "The core has not left chain proxy mode."));
    }
    Ok(())
}

/// Hooks so tests can run without a real core.
pub struct ChainHooks {
    pub validate: Box<dyn Fn(&Path, &str) -> Result<()>>,
    pub running: Box<dyn Fn(&Path) -> bool>,
    pub reload: Box<dyn Fn(&Path, &Path, &Map<String, Value>) -> Result<()>>,
}

impl Default for ChainHooks {
    fn default() -> ChainHooks {
        ChainHooks {
            validate: Box::new(validate_with_core),
            running: Box::new(support::core_running),
            reload: Box::new(reload_runtime),
        }
    }
}

fn validate_with_core(directory: &Path, runtime: &str) -> Result<()> {
    let work = support::temp_dir(".chain-validate-", Some(directory))?;
    let candidate = work.path().join("config.yaml");
    atomic_write(&candidate, runtime.as_bytes())?;
    let binary = directory.join(crate::paths::CORE_BINARY);
    let (directory_text, candidate_text) = (directory.to_string_lossy(), candidate.to_string_lossy());
    if !support::run(&binary, &["-t", "-d", &directory_text, "-f", &candidate_text], Duration::from_secs(20)).success() {
        return fail(t("链式配置未通过内核检查，本次未保存。", "The chain config failed the core check; nothing was saved."));
    }
    Ok(())
}

pub fn apply(directory: &Path, enabled: bool, entry: &str, exit: &str, hooks: &ChainHooks) -> Result<Map<String, Value>> {
    let source_path = directory.join("config.yaml");
    let source = read_text(&source_path).unwrap_or_default();
    let proxies = parse_subscription_file(&directory.join("providers/nodes.yaml"))?;
    let previous = read_state(directory)?;
    let metadata = directory.join(".mimio-chain.json");
    if !enabled && !flag(&previous, "enabled") {
        let state = json!({"enabled": false, "entry": entry, "exit": exit}).as_object().unwrap().clone();
        atomic_write(&metadata, json_text(&Value::Object(state.clone())).as_bytes())?;
        return Ok(state);
    }
    let (updated, mut state) = render(&source, &proxies, &previous, enabled, entry, exit)?;
    let secret = support::api_secret(directory);
    let runtime = updated.replace("__API_SECRET__", &secret);
    let runtime_path = directory.join(".run-config.yaml");
    let mut updates: BTreeMap<PathBuf, Vec<u8>> = BTreeMap::new();
    updates.insert(source_path.clone(), updated.into_bytes());
    updates.insert(runtime_path.clone(), runtime.clone().into_bytes());
    updates.insert(metadata, json_text(&Value::Object(state.clone())).into_bytes());
    let notun = directory.join(".config.yaml.notun");
    if let Some(text) = read_text(&notun) {
        updates.insert(notun, render(&text, &proxies, &previous, enabled, entry, exit)?.0.into_bytes());
    }
    (hooks.validate)(directory, &runtime)?;
    if read_text(&source_path).unwrap_or_default() != source {
        return fail(t("配置已发生变化，请重新打开设置。", "The config has changed. Reopen the settings."));
    }
    let saved = snapshot(updates.keys());
    let active = (hooks.running)(directory);
    let mut attempted = false;
    let attempt = (|| -> Result<()> {
        for (path, content) in &updates {
            atomic_write(path, content)?;
        }
        if active {
            attempted = true;
            (hooks.reload)(directory, &runtime_path, &state)?;
        }
        Ok(())
    })();
    if attempt.is_err() {
        let _ = restore(&saved);
        if attempted {
            if !runtime_path.exists() {
                let _ = atomic_write(&runtime_path, source.replace("__API_SECRET__", &secret).as_bytes());
            }
            if (hooks.reload)(directory, &runtime_path, &previous).is_err() {
                return Err(Error(t("保存失败，文件已恢复，但内核还原失败，请重新启动代理。", "Save failed. The files were restored, but restoring the core failed. Restart the proxy.")));
            }
        }
        return fail(t("链式设置未生效，已恢复原配置。", "Chain settings did not take effect; the original config was restored."));
    }
    state.insert("applied".into(), json!(active));
    Ok(state)
}

pub fn status(directory: &Path) -> Result<Map<String, Value>> {
    let mut result = read_state(directory)?;
    let proxies = parse_subscription_file(&directory.join("providers/nodes.yaml"))?;
    let names: Vec<Value> = proxies.iter().filter(|proxy| !matches!(type_of(proxy), "direct" | "reject")).map(|proxy| json!(name_of(proxy))).collect();
    result.insert("names".into(), Value::Array(names));
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::subscription::proxies_yaml;
    use crate::yaml::parse_yaml;

    fn proxies() -> Vec<Proxy> {
        json!([{"name": "入口测试", "type": "trojan", "server": "entry.example", "port": 443, "password": "fake-a"},
               {"name": "出口测试", "type": "trojan", "server": "exit.example", "port": 443, "password": "fake-b"}])
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_object().unwrap().clone())
        .collect()
    }

    const SOURCE: &str = "mixed-port: 7890\nsecret: \"__API_SECRET__\"\nfind-process-mode: off\ndns:\n  enable: true\n  direct-nameserver: [223.5.5.5]\nproxy-groups:\n  - name: PROXY\n    type: url-test\n    use: [nodes]\n    url: https://example.com/test\n  - name: 手动选择\n    type: select\n    use: [nodes]\nrules:\n  - DOMAIN-SUFFIX,local.example,DIRECT\n  - MATCH,PROXY\n";

    fn disabled() -> Map<String, Value> {
        json!({"enabled": false}).as_object().unwrap().clone()
    }

    #[test]
    fn two_hops_point_exit_to_entry_without_modifying_original() {
        let before = proxies();
        let result = chain_nodes(&before, "入口测试", "出口测试").unwrap();
        assert_eq!((name_of(&result[0]), name_of(&result[1])), (ENTRY, EXIT));
        assert_eq!(result[1]["dialer-proxy"], ENTRY);
        assert!(!result[0].contains_key("dialer-proxy"));
        assert_eq!(before, proxies());
    }

    #[test]
    fn same_missing_and_nonproxy_nodes_are_rejected() {
        assert!(chain_nodes(&proxies(), "入口测试", "入口测试").is_err());
        assert!(chain_nodes(&proxies(), "missing", "出口测试").is_err());
        let mut with_direct = proxies();
        with_direct.push(json!({"name": "direct", "type": "direct"}).as_object().unwrap().clone());
        assert!(chain_nodes(&with_direct, "direct", "出口测试").is_err());
    }

    #[test]
    fn render_enable_and_disable_preserve_rules_dns_and_modes() {
        let (updated, state) = render(SOURCE, &proxies(), &disabled(), true, "入口测试", "出口测试").unwrap();
        let data = parse_yaml(&updated).unwrap();
        assert_eq!(data["proxy-groups"][0]["proxies"], json!([EXIT]));
        assert_eq!(data["proxy-groups"][1]["proxies"], json!([EXIT]));
        assert!(updated.contains("find-process-mode: off"));
        assert_eq!(data["dns"]["direct-nameserver"], json!(["223.5.5.5"]));
        assert_eq!(data["dns"]["proxy-server-nameserver"], chain_dns());
        assert!(updated.contains(&SOURCE[SOURCE.find("rules:").unwrap()..]));
        let (restored, disabled_state) = render(&updated, &proxies(), &state, false, "入口测试", "出口测试").unwrap();
        let restored_data = parse_yaml(&restored).unwrap();
        let original = parse_yaml(SOURCE).unwrap();
        assert!(restored_data.get("proxies").is_none());
        assert_eq!(restored_data["proxy-groups"], original["proxy-groups"]);
        assert_eq!(restored_data["dns"], original["dns"]);
        assert_eq!(disabled_state["enabled"], false);
    }

    #[test]
    fn other_custom_nodes_and_groups_are_preserved() {
        let source = format!("{SOURCE}proxies:\n  - {{name: custom, type: direct}}\n");
        let (updated, state) = render(&source, &proxies(), &disabled(), true, "入口测试", "出口测试").unwrap();
        assert_eq!(parse_yaml(&updated).unwrap()["proxies"][0], json!({"name": "custom", "type": "direct"}));
        let changed = updated.replacen("proxies: [\"MIMIO_CHAIN_EXIT\"]", "proxies: [\"DIRECT\"]", 1);
        assert!(render(&changed, &proxies(), &state, false, "", "").is_err());
    }

    #[test]
    fn reload_failure_restores_all_files() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path();
        std::fs::create_dir_all(home.join("providers")).unwrap();
        std::fs::write(home.join("providers/nodes.yaml"), proxies_yaml(&proxies())).unwrap();
        std::fs::write(home.join("config.yaml"), SOURCE).unwrap();
        std::fs::write(home.join(".api-secret"), "fake-secret").unwrap();
        std::fs::write(home.join(".run-config.yaml"), SOURCE.replace("__API_SECRET__", "fake-secret")).unwrap();
        let before: Vec<Vec<u8>> = ["config.yaml", ".run-config.yaml"].iter().map(|name| std::fs::read(home.join(name)).unwrap()).collect();
        let calls = std::cell::Cell::new(0);
        let hooks = ChainHooks {
            validate: Box::new(|_, _| Ok(())),
            running: Box::new(|_| true),
            reload: Box::new(move |_, _, _| {
                calls.set(calls.get() + 1);
                if calls.get() == 1 { Err(Error("failed".into())) } else { Ok(()) }
            }),
        };
        assert!(apply(home, true, "入口测试", "出口测试", &hooks).is_err());
        let after: Vec<Vec<u8>> = ["config.yaml", ".run-config.yaml"].iter().map(|name| std::fs::read(home.join(name)).unwrap()).collect();
        assert_eq!(after, before);
        assert!(!home.join(".mimio-chain.json").exists());
    }

    #[test]
    fn subscription_refresh_updates_chain_credentials_and_handles_removed_node() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path();
        let (enabled, state) = render(SOURCE, &proxies(), &disabled(), true, "入口测试", "出口测试").unwrap();
        std::fs::write(home.join("config.yaml"), &enabled).unwrap();
        std::fs::write(home.join(".mimio-chain.json"), json_text(&Value::Object(state))).unwrap();
        std::fs::write(home.join(".api-secret"), "fake-secret").unwrap();
        let mut renewed = proxies();
        renewed[1].insert("password".into(), json!("renewed-secret"));
        let updates = subscription_updates(home, &renewed).unwrap();
        let config = parse_yaml(&String::from_utf8_lossy(&updates[&home.join("config.yaml")])).unwrap();
        let exit = config["proxies"].as_array().unwrap().iter().find(|proxy| proxy["name"] == EXIT).unwrap();
        assert_eq!(exit["password"], "renewed-secret");
        let updates = subscription_updates(home, &renewed[..1]).unwrap();
        let state = parse_yaml(&String::from_utf8_lossy(&updates[&home.join(".mimio-chain.json")])).unwrap();
        assert_eq!(state["enabled"], false);
        let config = parse_yaml(&String::from_utf8_lossy(&updates[&home.join("config.yaml")])).unwrap();
        assert_eq!(config["dns"], parse_yaml(SOURCE).unwrap()["dns"]);
    }
}
