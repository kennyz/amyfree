//! amyfree-helper: the runtime companion of the app and the scripts in the config folder.
//! Native code, so Amyfree needs no Python (or any other interpreter) at runtime.
//!
//!   subscription test|fetch|update|save [URL]
//!   node-speed [--home DIR] --list | --latency | --node NAME
//!   chain status|enable|disable [--home DIR] [--entry NAME] [--exit NAME]
//!   node-manager status|get|parse|save|delete [--home DIR] [--name NAME]   (parse/save read stdin)
//!   geodata [--home DIR] [--check] [--json] [--files NAME…]
//!   nodes PROVIDER API SECRET
//!   spawn-core BINARY DIR LOGFILE PIDFILE
//!   yaml-json                                                            (diagnostic: stdin YAML → JSON)

use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use amyfree_core::support::{self, t, Error};
use amyfree_core::yaml::json_text;
use amyfree_core::{chain, geodata, node_manager, speed, subscription};
use serde_json::{json, Map, Value};

const USAGE: &str = "usage: amyfree-helper subscription|node-speed|chain|node-manager|geodata|nodes|spawn-core|yaml-json …";

struct Options {
    positional: Vec<String>,
    values: HashMap<String, String>,
    flags: HashSet<String>,
    files: Vec<String>,
}

impl Options {
    fn parse(arguments: &[String]) -> Options {
        const VALUED: [&str; 5] = ["--home", "--entry", "--exit", "--name", "--node"];
        let mut options = Options { positional: vec![], values: HashMap::new(), flags: HashSet::new(), files: vec![] };
        let mut index = 0;
        while index < arguments.len() {
            let argument = &arguments[index];
            if argument == "--files" {
                index += 1;
                while index < arguments.len() && !arguments[index].starts_with("--") {
                    options.files.push(arguments[index].clone());
                    index += 1;
                }
                continue;
            }
            if VALUED.contains(&argument.as_str()) && index + 1 < arguments.len() {
                options.values.insert(argument.clone(), arguments[index + 1].clone());
                index += 2;
                continue;
            }
            if argument.starts_with("--") {
                options.flags.insert(argument.clone());
            } else {
                options.positional.push(argument.clone());
            }
            index += 1;
        }
        options
    }

    /// Defaults to the folder holding this executable (the runtime copy lives in the config folder).
    fn home(&self) -> PathBuf {
        if let Some(home) = self.values.get("--home") {
            return PathBuf::from(home);
        }
        std::env::current_exe()
            .ok()
            .and_then(|path| path.canonicalize().ok())
            .and_then(|path| path.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| PathBuf::from("."))
    }

    fn value(&self, key: &str) -> String {
        self.values.get(key).cloned().unwrap_or_default()
    }
}

fn read_stdin() -> String {
    let mut text = String::new();
    let _ = std::io::stdin().read_to_string(&mut text);
    text
}

/// JSON commands print one object; failures print {"error": …} (or {"ok": false, …}) and exit 1.
fn json_command(ok_key: bool, body: impl FnOnce() -> support::Result<Value>) -> ExitCode {
    match body() {
        Ok(value) => {
            support::say(&json_text(&value));
            ExitCode::SUCCESS
        }
        Err(Error(message)) => {
            let mut object = Map::new();
            if ok_key {
                object.insert("ok".into(), json!(false));
            }
            object.insert("error".into(), json!(message));
            support::say(&json_text(&Value::Object(object)));
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    #[cfg(unix)]
    unsafe {
        libc::umask(0o077);
    }
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = arguments.first() else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let options = Options::parse(&arguments[1..]);
    let home = options.home();
    match command.as_str() {
        "subscription" => {
            let Some(operation) = options.positional.first().filter(|operation| ["test", "fetch", "update", "save"].contains(&operation.as_str())) else {
                eprintln!("usage: amyfree-helper subscription test|fetch|update|save [URL]");
                return ExitCode::from(2);
            };
            let url = options.positional.get(1).map(String::as_str);
            match subscription::SubscriptionManager::new(&home).execute(operation, url) {
                Ok(()) => ExitCode::SUCCESS,
                Err(Error(message)) => {
                    // Messages are fixed, user-facing text; parser and curl output (which may hold credentials) never reach here.
                    eprintln!("✗ {message}");
                    ExitCode::FAILURE
                }
            }
        }
        "node-speed" => {
            support::install_termination_handler();
            json_command(true, || {
                if options.flags.contains("--latency") {
                    return speed::latency_batch(&home).map(Value::Object);
                }
                if options.flags.contains("--list") {
                    return speed::catalogue(&home).map(Value::Object);
                }
                if let Some(node) = options.values.get("--node") {
                    return speed::measure(&home, node).map(Value::Object);
                }
                Err(Error(t("请选择一个节点", "Choose a node")))
            })
        }
        "chain" => json_command(false, || match options.positional.first().map(String::as_str) {
            Some("status") => chain::status(&home).map(Value::Object),
            Some(action @ ("enable" | "disable")) => {
                chain::apply(&home, action == "enable", &options.value("--entry"), &options.value("--exit"), &chain::ChainHooks::default()).map(Value::Object)
            }
            _ => Err(Error(t("无法读取或应用链式配置。", "Could not read or apply the chain config."))),
        }),
        "node-manager" => json_command(false, || {
            let name = options.value("--name");
            let hooks = node_manager::NodeHooks::default();
            match options.positional.first().map(String::as_str) {
                Some("status") => node_manager::status(&home),
                Some("get") => node_manager::get(&home, &name),
                Some("parse") => node_manager::parse(&read_stdin()),
                Some("save") => node_manager::save(&home, &name, &read_stdin(), &hooks),
                Some("delete") => node_manager::delete(&home, &name, &hooks),
                _ => Err(Error("usage: amyfree-helper node-manager status|get|parse|save|delete".into())),
            }
        }),
        "geodata" => {
            let code = geodata::command(&home, options.flags.contains("--check"), options.flags.contains("--json"), &options.files);
            ExitCode::from(code as u8)
        }
        "nodes" => {
            let values = &options.positional;
            let provider = values.first().map(String::as_str).unwrap_or("nodes");
            let api = values.get(1).map(String::as_str).unwrap_or("127.0.0.1:9090");
            let secret = values.get(2).map(String::as_str).unwrap_or("");
            ExitCode::from(speed::list_nodes(provider, api, secret) as u8)
        }
        "spawn-core" => {
            // Starts the core in its own session so it survives the calling shell or app exiting.
            let [binary, directory, log, pid_file] = options.positional.as_slice() else {
                eprintln!("usage: amyfree-helper spawn-core BINARY DIR LOGFILE PIDFILE");
                return ExitCode::from(2);
            };
            let config = format!("{directory}/.run-config.yaml");
            match support::spawn_detached(Path::new(binary), &["-d", directory, "-f", &config], Path::new(log), Path::new(directory)) {
                Ok(pid) => {
                    if std::fs::write(pid_file, pid.to_string()).is_err() {
                        return ExitCode::FAILURE;
                    }
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        let _ = std::fs::set_permissions(pid_file, std::fs::Permissions::from_mode(0o644));
                    }
                    ExitCode::SUCCESS
                }
                Err(_) => ExitCode::FAILURE,
            }
        }
        "yaml-json" => match amyfree_core::yaml::parse_yaml(&read_stdin()) {
            Ok(value) => {
                support::say(&json_text(&value));
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("{error}");
                ExitCode::FAILURE
            }
        },
        other => {
            eprintln!("unknown command: {other}\n{USAGE}");
            ExitCode::from(2)
        }
    }
}
