//! Node management: hand-added nodes and edits to subscription nodes, kept across subscription updates.
//!
//! The subscription as downloaded lives in `providers/subscription.yaml`, manual changes in
//! `custom-nodes.json`; the merge of both is written to `providers/nodes.yaml`, which the core loads.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Map, Value};

use crate::subscription::{check_nodes_with_core, link_parser, load_yaml, name_of, parse_subscription_file, proxies_yaml, type_of, validate_proxies, Proxy};
use crate::support::{self, atomic_write, fail, read_text, restore, say, snapshot, t, Error, Result};
use crate::yaml::{json_text, to_yaml};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct NodeStore {
    pub added: Vec<Proxy>,
    /// Original subscription name → edited node.
    pub edited: Map<String, Value>,
}

fn store_path(directory: &Path) -> PathBuf {
    directory.join("custom-nodes.json")
}

pub fn read_store(directory: &Path) -> Result<NodeStore> {
    let Some(text) = read_text(&store_path(directory)) else { return Ok(NodeStore::default()) };
    let Value::Object(value) = load_yaml(&text)? else { return Ok(NodeStore::default()) };
    let added = value.get("added").and_then(Value::as_array).map(|items| items.iter().filter_map(|item| item.as_object().cloned()).collect()).unwrap_or_default();
    let edited = value.get("edited").and_then(Value::as_object).cloned().unwrap_or_default();
    Ok(NodeStore { added, edited })
}

fn store_json(store: &NodeStore) -> String {
    json_text(&json!({"added": store.added, "edited": store.edited}))
}

/// Applies edits by original name, then appends added nodes; on a name clash the first one wins.
pub fn merge(base: &[Proxy], store: &NodeStore) -> (Vec<Proxy>, Vec<String>) {
    let mut merged = Vec::new();
    let mut names = HashSet::new();
    let mut skipped = Vec::new();
    let edited = base.iter().map(|proxy| store.edited.get(name_of(proxy)).and_then(Value::as_object).cloned().unwrap_or_else(|| proxy.clone()));
    for proxy in edited.chain(store.added.iter().cloned()) {
        if names.insert(name_of(&proxy).to_string()) {
            merged.push(proxy);
        } else {
            skipped.push(name_of(&proxy).to_string());
        }
    }
    (merged, skipped)
}

/// Used when the subscription updates: returns the subscription unchanged when there are no manual changes.
pub fn merge_custom_nodes(directory: &Path, base: Vec<Proxy>) -> Vec<Proxy> {
    let (merged, skipped) = merge(&base, &read_store(directory).unwrap_or_default());
    if !skipped.is_empty() {
        say(&(t("! 以下自定义节点与订阅节点重名，本次未加载：", "! These custom nodes share a name with subscription nodes and were not loaded: ") + &skipped.join(&t("、", ", "))));
    }
    merged
}

pub fn read_base(directory: &Path) -> Result<Vec<Proxy>> {
    // Before the first edit, nodes.yaml is still exactly the subscription.
    for path in [directory.join("providers/subscription.yaml"), directory.join("providers/nodes.yaml")] {
        if path.exists() {
            return parse_subscription_file(&path);
        }
    }
    Ok(Vec::new())
}

/// (kind, key): "added" is keyed by its current name; "edited"/"subscription" by the subscription name.
pub fn origin(store: &NodeStore, base: &[Proxy], current: &str) -> Result<(&'static str, String)> {
    if store.added.iter().any(|proxy| name_of(proxy) == current) {
        return Ok(("added", current.to_string()));
    }
    for proxy in base {
        let edited = store.edited.get(name_of(proxy)).and_then(Value::as_object);
        if name_of(edited.unwrap_or(proxy)) == current {
            return Ok((if edited.is_some() { "edited" } else { "subscription" }, name_of(proxy).to_string()));
        }
    }
    fail(t("节点已不存在，请重新打开节点管理。", "The node no longer exists. Reopen Node Management."))
}

/// Form submissions are unordered JSON; list the common fields first so the source view reads well.
const FIELD_ORDER: [&str; 18] = ["name", "type", "server", "port", "cipher", "uuid", "alterId", "username", "password", "flow",
                                 "tls", "servername", "sni", "skip-cert-verify", "network", "ws-opts", "grpc-opts", "udp"];

pub fn ordered(proxy: &Proxy) -> Proxy {
    let mut result = Proxy::new();
    for key in FIELD_ORDER {
        if let Some(value) = proxy.get(key) {
            result.insert(key.into(), value.clone());
        }
    }
    for (key, value) in proxy {
        if !result.contains_key(key) {
            result.insert(key.clone(), value.clone());
        }
    }
    result
}

/// Accepts one share link or one node's Clash YAML/JSON. `strict = false` allows half-filled nodes (form/source switching).
pub fn parse_node(input: &str, strict: bool) -> Result<Proxy> {
    let text = input.trim();
    if text.is_empty() {
        if !strict {
            return Ok(Proxy::new());
        }
        return fail(t("请粘贴节点链接或节点配置。", "Paste a node link or node config."));
    }
    let first_line = text.lines().next().unwrap_or("");
    let scheme = first_line.split_once("://").map(|(scheme, _)| scheme.to_lowercase()).unwrap_or_default();
    let proxy = if let Some(parser) = link_parser(&scheme) {
        if text.lines().count() > 1 {
            return fail(t("一次只能添加一个节点链接。", "Add one node link at a time."));
        }
        parser(text).map_err(|_| Error(t("节点链接格式不正确。", "The node link is malformed.")))?
    } else {
        let mut value = load_yaml(text)?;
        if let Some(Value::Array(list)) = value.get("proxies") {
            value = Value::Array(list.clone());
        }
        if let Value::Array(list) = value {
            if list.len() != 1 {
                return fail(t("一次只能保存一个节点。", "Save one node at a time."));
            }
            value = list.into_iter().next().unwrap();
        }
        let Value::Object(object) = value else {
            return fail(t("无法识别节点配置，请使用 vless/vmess/ss/trojan 链接或 Clash 节点 YAML。", "Unrecognised node config. Use a vless/vmess/ss/trojan link or Clash node YAML."));
        };
        if text.starts_with('{') { ordered(&object) } else { object }
    };
    if !strict {
        return Ok(proxy);
    }
    validate_proxies(Some(&json!([proxy])))?;
    if matches!(type_of(&proxy), "direct" | "reject") {
        return fail(t("请填写实际代理节点。", "Enter a real proxy node."));
    }
    Ok(proxy)
}

/// Hooks so tests can run without a real core.
pub struct NodeHooks {
    pub validate: Box<dyn Fn(&Path, &[Proxy]) -> Result<()>>,
    pub reload: Box<dyn Fn(&Path, &[Proxy], bool) -> Result<()>>,
    pub running: Box<dyn Fn(&Path) -> bool>,
}

impl Default for NodeHooks {
    fn default() -> NodeHooks {
        NodeHooks { validate: Box::new(check_nodes_with_core), reload: Box::new(reload_nodes), running: Box::new(support::core_running) }
    }
}

fn reload_nodes(directory: &Path, merged: &[Proxy], config_changed: bool) -> Result<()> {
    let authorization = format!("Bearer {}", support::api_secret(directory));
    let headers = [("Authorization", authorization.as_str()), ("Content-Type", "application/json")];
    let api = support::api_address();
    let timeout = Duration::from_secs(12);
    let response = if config_changed {
        let body = json_text(&json!({ "path": directory.join(".run-config.yaml").to_string_lossy() }));
        support::http("PUT", &format!("http://{api}/configs?force=true"), &headers, Some(body.as_bytes()), timeout)?
    } else {
        support::http("PUT", &format!("http://{api}/providers/proxies/nodes"), &headers, None, timeout)?
    };
    if !(200..300).contains(&response.status) {
        return fail("reload failed".into());
    }
    let listed = support::http("GET", &format!("http://{api}/providers/proxies/nodes"), &headers, None, timeout)?;
    let loaded: Vec<String> = listed
        .json()
        .and_then(|value| value.get("proxies").and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|proxy| proxy.get("name").and_then(Value::as_str).map(str::to_string))
        .collect();
    if loaded != merged.iter().map(|proxy| name_of(proxy).to_string()).collect::<Vec<_>>() {
        return fail(t("内核未能加载更新后的节点列表。", "The core did not load the updated node list."));
    }
    Ok(())
}

/// Validates and writes the merged result; reloads a running core, restoring every file on failure.
fn commit(directory: &Path, base: &[Proxy], store: &NodeStore, hooks: &NodeHooks) -> Result<bool> {
    let (merged, skipped) = merge(base, store);
    if let Some(clash) = skipped.first() {
        return fail(t(&format!("节点名称「{clash}」已存在，请换一个名称。"), &format!("A node named \"{clash}\" already exists. Choose another name.")));
    }
    (hooks.validate)(directory, &merged)?;
    let mut updates: BTreeMap<PathBuf, Vec<u8>> = crate::chain::subscription_updates(directory, &merged)?;
    let config_changed = !updates.is_empty();
    updates.insert(directory.join("providers/subscription.yaml"), proxies_yaml(base).into_bytes());
    updates.insert(directory.join("providers/nodes.yaml"), proxies_yaml(&merged).into_bytes());
    updates.insert(store_path(directory), store_json(store).into_bytes());
    let running = (hooks.running)(directory);
    if !running {
        // While stopped, the runtime config is regenerated at the next start.
        updates.remove(&directory.join(".run-config.yaml"));
    }
    let saved = snapshot(updates.keys());
    let attempt = (|| -> Result<()> {
        for (path, content) in &updates {
            atomic_write(path, content)?;
        }
        if running {
            (hooks.reload)(directory, &merged, config_changed)?;
        }
        Ok(())
    })();
    if attempt.is_err() {
        let _ = restore(&saved);
        if running {
            let previous = merge(base, &read_store(directory).unwrap_or_default()).0;
            if (hooks.reload)(directory, &previous, config_changed).is_err() {
                return fail(t("保存失败，文件已恢复，但内核还原失败，请重新启动代理。", "Save failed. The files were restored, but restoring the core failed. Restart the proxy."));
            }
        }
        return fail(t("节点修改未生效，已恢复原配置。", "The node change did not take effect; the previous config was restored."));
    }
    Ok(running)
}

pub fn status(directory: &Path) -> Result<Value> {
    let (store, base) = (read_store(directory)?, read_base(directory)?);
    let nodes = merge(&base, &store)
        .0
        .iter()
        .map(|proxy| Ok(json!({"name": name_of(proxy), "origin": origin(&store, &base, name_of(proxy))?.0})))
        .collect::<Result<Vec<_>>>()?;
    Ok(json!({ "nodes": nodes }))
}

pub fn get(directory: &Path, current: &str) -> Result<Value> {
    let (store, base) = (read_store(directory)?, read_base(directory)?);
    let (kind, _) = origin(&store, &base, current)?;
    let proxy = merge(&base, &store).0.into_iter().find(|proxy| name_of(proxy) == current).unwrap_or_default();
    Ok(json!({"name": current, "origin": kind, "node": proxy, "config": to_yaml(&proxy, 0) + "\n"}))
}

pub fn save(directory: &Path, original: &str, text: &str, hooks: &NodeHooks) -> Result<Value> {
    let (mut store, base) = (read_store(directory)?, read_base(directory)?);
    let proxy = parse_node(text, true)?;
    if original.is_empty() {
        store.added.push(proxy.clone());
    } else {
        let (kind, key) = origin(&store, &base, original)?;
        if kind == "added" {
            for item in &mut store.added {
                if name_of(item) == key {
                    *item = proxy.clone();
                }
            }
        } else if base.iter().find(|item| name_of(item) == key) == Some(&proxy) {
            store.edited.remove(&key);
        } else {
            store.edited.insert(key, Value::Object(proxy.clone()));
        }
    }
    let applied = commit(directory, &base, &store, hooks)?;
    Ok(json!({"name": name_of(&proxy), "applied": applied}))
}

pub fn delete(directory: &Path, current: &str, hooks: &NodeHooks) -> Result<Value> {
    let (mut store, base) = (read_store(directory)?, read_base(directory)?);
    let (kind, key) = origin(&store, &base, current)?;
    match kind {
        "subscription" => return fail(t("订阅节点不能删除，更新订阅时会重新出现。", "Subscription nodes cannot be deleted; they return when the subscription updates.")),
        "added" => store.added.retain(|proxy| name_of(proxy) != key),
        _ => {
            store.edited.remove(&key);
        }
    }
    let applied = commit(directory, &base, &store, hooks)?;
    Ok(json!({"name": current, "origin": kind, "applied": applied}))
}

pub fn parse(text: &str) -> Result<Value> {
    let proxy = parse_node(text, false)?;
    let config = if proxy.is_empty() { String::new() } else { to_yaml(&proxy, 0) + "\n" };
    Ok(json!({"node": proxy, "config": config}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::yaml::parse_yaml;
    use std::cell::RefCell;
    use std::rc::Rc;

    const LINK: &str = "trojan://fake-c@c.example:8443?sni=c.example#%E6%89%8B%E5%B7%A5%E4%B8%99";

    fn subscription() -> Vec<Proxy> {
        json!([{"name": "订阅甲", "type": "trojan", "server": "a.example", "port": 443, "password": "fake-a"},
               {"name": "订阅乙", "type": "trojan", "server": "b.example", "port": 443, "password": "fake-b"}])
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_object().unwrap().clone())
        .collect()
    }

    struct Home {
        directory: tempfile::TempDir,
        hooks: NodeHooks,
        reloads: Rc<RefCell<Vec<Result<()>>>>,
    }

    fn home(running: bool) -> Home {
        let directory = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(directory.path().join("providers")).unwrap();
        std::fs::write(directory.path().join("providers/nodes.yaml"), proxies_yaml(&subscription())).unwrap();
        let reloads: Rc<RefCell<Vec<Result<()>>>> = Rc::new(RefCell::new(Vec::new()));
        let queue = reloads.clone();
        let hooks = NodeHooks {
            validate: Box::new(|_, _| Ok(())),
            reload: Box::new(move |_, _, _| if queue.borrow().is_empty() { Ok(()) } else { queue.borrow_mut().remove(0) }),
            running: Box::new(move |_| running),
        };
        Home { directory, hooks, reloads }
    }

    impl Home {
        fn path(&self) -> &Path {
            self.directory.path()
        }
        fn loaded(&self) -> Vec<Value> {
            parse_yaml(&std::fs::read_to_string(self.path().join("providers/nodes.yaml")).unwrap()).unwrap()["proxies"].as_array().unwrap().clone()
        }
        fn names(&self) -> Vec<String> {
            self.loaded().iter().map(|proxy| proxy["name"].as_str().unwrap().to_string()).collect()
        }
    }

    #[test]
    fn parse_link_yaml_json_and_reject_bad_input() {
        assert_eq!(parse_node(LINK, true).unwrap()["name"], "手工丙");
        assert_eq!(parse_node(&to_yaml(&subscription()[0], 0), true).unwrap()["port"], 443);
        assert_eq!(parse_node(&json!({"proxies": [subscription()[1]]}).to_string(), true).unwrap(), subscription()[1]);
        let both = json!(subscription()).to_string();
        for text in ["", "hello", &format!("{LINK}\n{LINK}"), &both, "name: x\ntype: direct\n", "name: x\ntype: trojan\nserver: s\nport: 70000\n"] {
            assert!(parse_node(text, true).is_err(), "{text}");
        }
    }

    #[test]
    fn add_edit_and_delete_custom_node() {
        let home = home(false);
        assert_eq!(save(home.path(), "", LINK, &home.hooks).unwrap(), json!({"name": "手工丙", "applied": false}));
        assert_eq!(home.names(), ["订阅甲", "订阅乙", "手工丙"]);
        assert_eq!(status(home.path()).unwrap()["nodes"][2], json!({"name": "手工丙", "origin": "added"}));
        let edited = get(home.path(), "手工丙").unwrap()["config"].as_str().unwrap().replace("8443", "9443");
        save(home.path(), "手工丙", &edited, &home.hooks).unwrap();
        assert_eq!(home.loaded()[2]["port"], 9443);
        delete(home.path(), "手工丙", &home.hooks).unwrap();
        assert_eq!(home.loaded(), json!(subscription()).as_array().unwrap().clone());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(home.path().join("custom-nodes.json")).unwrap().permissions().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn edited_subscription_node_survives_refresh_and_restores() {
        let home = home(false);
        let renamed = get(home.path(), "订阅甲").unwrap()["config"].as_str().unwrap().replace("订阅甲", "我的甲").replace("a.example", "mine.example");
        save(home.path(), "订阅甲", &renamed, &home.hooks).unwrap();
        assert_eq!(home.loaded()[0]["server"], "mine.example");
        assert_eq!(status(home.path()).unwrap()["nodes"][0], json!({"name": "我的甲", "origin": "edited"}));
        let mut renewed = subscription();
        renewed[0].insert("password".into(), json!("renewed"));
        assert_eq!(merge_custom_nodes(home.path(), renewed)[0]["server"], "mine.example");
        delete(home.path(), "我的甲", &home.hooks).unwrap();
        assert_eq!(home.loaded(), json!(subscription()).as_array().unwrap().clone());
        assert!(delete(home.path(), "订阅乙", &home.hooks).is_err());
    }

    #[test]
    fn unchanged_save_is_not_recorded_as_edit() {
        let home = home(false);
        let config = get(home.path(), "订阅乙").unwrap()["config"].as_str().unwrap().to_string();
        save(home.path(), "订阅乙", &config, &home.hooks).unwrap();
        assert!(read_store(home.path()).unwrap().edited.is_empty());
    }

    #[test]
    fn duplicate_name_is_rejected_without_changes() {
        let home = home(false);
        let mut clash = subscription()[0].clone();
        clash.insert("server".into(), json!("x.example"));
        assert!(save(home.path(), "", &to_yaml(&clash, 0), &home.hooks).is_err());
        assert!(!home.path().join("custom-nodes.json").exists());
    }

    #[test]
    fn refresh_skips_custom_node_that_now_clashes() {
        let home = home(false);
        save(home.path(), "", LINK, &home.hooks).unwrap();
        let mut clash = subscription();
        let mut renamed = clash[0].clone();
        renamed.insert("name".into(), json!("手工丙"));
        clash.push(renamed);
        let merged = merge_custom_nodes(home.path(), clash);
        assert_eq!(merged.iter().map(|proxy| name_of(proxy)).collect::<Vec<_>>(), ["订阅甲", "订阅乙", "手工丙"]);
        assert_eq!(merged[2]["server"], "a.example");
    }

    #[test]
    fn reload_failure_restores_files() {
        let home = home(true);
        let before = std::fs::read(home.path().join("providers/nodes.yaml")).unwrap();
        home.reloads.borrow_mut().extend([Err(Error("failed".into())), Ok(())]);
        assert!(save(home.path(), "", LINK, &home.hooks).is_err());
        assert_eq!(std::fs::read(home.path().join("providers/nodes.yaml")).unwrap(), before);
        assert!(!home.path().join("custom-nodes.json").exists());
    }

    #[test]
    fn lenient_parse_for_form_and_source_switching() {
        assert!(parse_node("", false).unwrap().is_empty());
        let partial = parse_node(r#"{"udp": true, "type": "vless", "port": 443}"#, false).unwrap();
        assert_eq!(partial.keys().collect::<Vec<_>>(), ["type", "port", "udp"]);
        assert_eq!(parse_node(LINK, false).unwrap()["server"], "c.example");
        assert!(parse_node("[1, 2]", false).is_err());
        let home = home(false);
        assert!(get(home.path(), "订阅甲").unwrap().get("node").is_some());
    }
}
