//! Downloads and validates a complete Geo database set before replacing it transactionally.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

use crate::support::{self, atomic_write, fail, read_text, say, t, Context, Error, Result};
use crate::yaml::json_text;

pub const FILES: [&str; 3] = ["geoip.dat", "geosite.dat", "country.mmdb"];
pub const DEFAULT_BASE: &str = "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release";

pub fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Small public JSON documents (GitHub metadata); empty on any failure.
pub fn public_metadata(url: &str) -> Map<String, Value> {
    let result = support::run(
        Path::new(crate::paths::CURL),
        &["-fLsS", "--connect-timeout", "8", "--max-time", "15", "--proto", "=https", "--proto-redir", "=https", url],
        Duration::from_secs(20),
    );
    if !result.success() {
        return Map::new();
    }
    serde_json::from_slice::<Value>(&result.stdout).ok().and_then(|value| value.as_object().cloned()).unwrap_or_default()
}

/// Network lookups, replaceable in tests.
pub struct Metadata {
    pub fetch: Box<dyn Fn(&str) -> Map<String, Value>>,
}

impl Default for Metadata {
    fn default() -> Metadata {
        Metadata { fetch: Box::new(public_metadata) }
    }
}

impl Metadata {
    /// Pins all files to one revision so the size and checksum describe the same data.
    pub fn resolve_source(&self, base: &str) -> String {
        if base != DEFAULT_BASE {
            return base.to_string();
        }
        let revision = (self.fetch)("https://api.github.com/repos/MetaCubeX/meta-rules-dat/commits/release")
            .get("sha")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if revision.len() == 40 && revision.bytes().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()) {
            base.replace("@release", &format!("@{revision}"))
        } else {
            base.to_string()
        }
    }

    pub fn remote_size(&self, url: &str) -> u64 {
        let pattern = regex::Regex::new(r"^https://testingcf\.jsdelivr\.net/gh/MetaCubeX/meta-rules-dat@([0-9a-f]{40})/(geoip\.dat|geosite\.dat|country\.mmdb)$").unwrap();
        let Some(captures) = pattern.captures(url) else { return 0 };
        let metadata = (self.fetch)(&format!("https://api.github.com/repos/MetaCubeX/meta-rules-dat/contents/{}?ref={}", &captures[2], &captures[1]));
        metadata.get("size").and_then(Value::as_u64).filter(|size| *size > 0).unwrap_or(0)
    }
}

/// Content-Length of the final 2xx response only; a redirect's body size must not count.
pub fn response_size(headers: &str) -> u64 {
    let normalized = headers.replace("\r\n", "\n");
    let Some(last) = normalized.split("\n\n").map(str::trim).filter(|block| block.starts_with("HTTP/")).last() else { return 0 };
    let status_ok = regex::Regex::new(r"^HTTP/\S+\s+2\d\d\b").unwrap().is_match(last);
    if !status_ok {
        return 0;
    }
    last.lines()
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse().ok())
        .unwrap_or(0)
}

fn download_failure() -> Error {
    Error(t("下载失败，请检查网络后重试。原规则库未修改。", "Download failed. Check your network and try again. The existing rule data was not changed."))
}

/// Downloads with curl; with a progress callback, reports bytes on disk while it runs.
pub fn fetch(url: &str, target: &Path, progress: Option<&mut dyn FnMut(u64, u64)>, metadata: &Metadata) -> Result<()> {
    let target_text = target.to_string_lossy().into_owned();
    let mut args = vec!["-fLsS", "--connect-timeout", "20", "--max-time", "180", "--retry", "2", "--proto", "=https", "--proto-redir", "=https", url, "-o", &target_text];
    let Some(progress) = progress else {
        return if support::run(Path::new(crate::paths::CURL), &args, Duration::from_secs(600)).success() { Ok(()) } else { Err(download_failure()) };
    };
    let known_total = metadata.remote_size(url);
    progress(0, known_total);
    let headers = PathBuf::from(format!("{target_text}.headers"));
    let headers_text = headers.to_string_lossy().into_owned();
    args.extend(["--dump-header", &headers_text]);
    let mut child = Command::new(crate::paths::CURL).args(&args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map_err(|_| download_failure())?;
    let size = |path: &Path| fs::metadata(path).map(|metadata| metadata.len()).unwrap_or(0);
    let deadline = Instant::now() + Duration::from_secs(600);
    let status = loop {
        let total = if known_total > 0 { known_total } else { response_size(&read_text(&headers).unwrap_or_default()) };
        progress(size(target), total);
        if let Ok(Some(status)) = child.try_wait() {
            break status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            return fail(t("下载超时，请稍后重试。", "Download timed out. Please try again later."));
        }
        thread::sleep(Duration::from_millis(150));
    };
    if !status.success() {
        return Err(download_failure());
    }
    let completed = size(target);
    progress(completed, completed);
    Ok(())
}

fn checksum(base: &str, name: &str, stage: &Path, download: &mut dyn FnMut(&str, &Path) -> Result<()>) -> Result<String> {
    let path = stage.join(format!("{name}.sha256sum"));
    download(&format!("{base}/{name}.sha256sum"), &path)?;
    let expected = read_text(&path).unwrap_or_default().split_whitespace().next().unwrap_or("").to_lowercase();
    if expected.len() != 64 || !expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return fail(t("无法读取规则库校验值，原规则库未修改。", "Could not read the rule data checksum. The existing rule data was not changed."));
    }
    Ok(expected)
}

fn base_url() -> String {
    std::env::var("GEODATA_BASE").unwrap_or_else(|_| DEFAULT_BASE.into()).trim_end_matches('/').to_string()
}

/// Compares the published checksums with the local files; downloads no databases.
pub fn check(directory: &Path, download: Option<&mut dyn FnMut(&str, &Path) -> Result<()>>, metadata: &Metadata) -> Result<Map<String, Value>> {
    let real = download.is_none();
    let mut default_download = |url: &str, path: &Path| fetch(url, path, None, metadata);
    let download: &mut dyn FnMut(&str, &Path) -> Result<()> = match download {
        Some(download) => download,
        None => &mut default_download,
    };
    let base = if real { metadata.resolve_source(&base_url()) } else { base_url() };
    let stage = support::temp_dir("amyfree-geo-check-", None)?;
    let mut result = Map::new();
    for name in FILES {
        let expected = checksum(&base, name, stage.path(), download)?;
        let local = directory.join(name);
        let available = fs::read(&local).map(|data| sha256_hex(&data) != expected).unwrap_or(true);
        let modified = fs::metadata(&local).ok().and_then(|metadata| metadata.modified().ok()).and_then(|time| time.duration_since(UNIX_EPOCH).ok()).map(|age| age.as_secs_f64());
        result.insert(name.into(), json!({"available": available, "modified": modified}));
    }
    Ok(result)
}

/// Has the real core read each format, with no private nodes or bound ports.
pub fn validate(stage: &Path, core: &Path) -> Result<()> {
    for dat_mode in [true, false] {
        let config = stage.join("validate.json");
        let document = json!({"mixed-port": 0, "geo-auto-update": false, "geodata-mode": dat_mode, "rules": ["GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT", "MATCH,DIRECT"]});
        atomic_write(&config, json_text(&document).as_bytes())?;
        let (stage_text, config_text) = (stage.to_string_lossy(), config.to_string_lossy());
        if !support::run(core, &["-t", "-d", &stage_text, "-f", &config_text], Duration::from_secs(60)).success() {
            return fail(t("规则库格式检查失败，原规则库未修改。", "Rule data format check failed. The existing rule data was not changed."));
        }
    }
    Ok(())
}

pub fn replace(source: &Path, target: &Path) -> Result<()> {
    let name = target.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = target.with_file_name(format!(".{name}.incoming"));
    let result = (|| -> std::io::Result<()> {
        let _ = fs::remove_file(&temporary);
        fs::copy(source, &temporary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&temporary, fs::Permissions::from_mode(0o644))?;
        }
        fs::rename(&temporary, target)
    })();
    let _ = fs::remove_file(&temporary);
    result.or_msg("replace failed".into())
}

/// Replaceable steps for tests; `None` uses the real network, core check and file replacement.
#[derive(Default)]
pub struct UpdateSteps<'a> {
    pub download: Option<&'a mut dyn FnMut(&str, &Path) -> Result<()>>,
    pub validator: Option<&'a dyn Fn(&Path, &Path) -> Result<()>>,
    pub replacer: Option<&'a dyn Fn(&Path, &Path) -> Result<()>>,
}

pub fn update(directory: &Path, steps: UpdateSteps, selected: &[&str], mut progress: Option<&mut dyn FnMut(Map<String, Value>)>, metadata: &Metadata) -> Result<String> {
    let unique: std::collections::HashSet<&&str> = selected.iter().collect();
    if selected.is_empty() || unique.len() != selected.len() || !selected.iter().all(|name| FILES.contains(name)) {
        return fail(t("规则库名称无效。", "Invalid rule data name."));
    }
    let core = directory.join(crate::paths::CORE_BINARY);
    if !core.is_file() {
        return fail(t("尚未安装 mihomo 内核，请先安装 Amyfree。", "The mihomo core is not installed. Install Amyfree first."));
    }
    // Keep the lock file's inode stable: unlinking flock files would allow overlapping updates.
    let Some(_lock) = support::try_lock(&directory.join(".geodata-update.lock")) else {
        return fail(t("规则库正在更新，请等待完成。", "Rule data is already updating. Please wait for it to finish."));
    };
    let real = steps.download.is_none();
    let mut default_download = |url: &str, path: &Path| fetch(url, path, None, metadata);
    let download: &mut dyn FnMut(&str, &Path) -> Result<()> = match steps.download {
        Some(download) => download,
        None => &mut default_download,
    };
    let base = if real { metadata.resolve_source(&base_url()) } else { base_url() };
    let stage_dir = support::temp_dir(".geodata-update-", Some(directory))?;
    let stage = stage_dir.path();
    let has_progress = progress.is_some();
    let mut emit = |event: Value| {
        if let Some(progress) = progress.as_mut() {
            progress(event.as_object().unwrap().clone());
        }
    };
    for name in FILES {
        if !selected.contains(&name) {
            if !directory.join(name).is_file() {
                return fail(t("缺少其他规则库，请先完整安装 Amyfree。", "Other rule data files are missing. Do a full Amyfree install first."));
            }
            fs::copy(directory.join(name), stage.join(name)).or_msg(t("无法读取规则库。", "Could not read the rule data."))?;
            continue;
        }
        if has_progress {
            emit(json!({"phase": "downloading", "file": name, "downloaded": 0, "total": 0}));
        } else {
            say(&(t("正在下载 ", "Downloading ") + name + "…"));
        }
        let expected = checksum(&base, name, stage, download)?;
        let target = stage.join(name);
        if has_progress && real {
            let mut report = |received: u64, total: u64| emit(json!({"phase": "downloading", "file": name, "downloaded": received, "total": total}));
            fetch(&format!("{base}/{name}"), &target, Some(&mut report), metadata)?;
        } else {
            download(&format!("{base}/{name}"), &target)?;
            let size = fs::metadata(&target).map(|metadata| metadata.len()).unwrap_or(0);
            if has_progress {
                emit(json!({"phase": "downloading", "file": name, "downloaded": size, "total": size}));
            }
        }
        if sha256_hex(&fs::read(&target).unwrap_or_default()) != expected {
            return fail(name.to_string() + &t(" 校验失败，原规则库未修改，请稍后重试。", " failed verification. The existing rule data was not changed. Please try again later."));
        }
    }
    if has_progress {
        emit(json!({"phase": "validating"}));
    }
    match steps.validator {
        Some(validator) => validator(stage, &core)?,
        None => validate(stage, &core)?,
    }
    if FILES.iter().all(|name| fs::read(directory.join(name)).ok() == fs::read(stage.join(name)).ok() && directory.join(name).is_file()) {
        return Ok(t("规则库已是最新版本。", "Rule data is up to date."));
    }
    let backup = stage.join("backup");
    fs::create_dir_all(&backup).or_msg(t("无法备份规则库。", "Could not back up the rule data."))?;
    for name in FILES {
        if directory.join(name).exists() {
            fs::copy(directory.join(name), backup.join(name)).or_msg(t("无法备份规则库。", "Could not back up the rule data."))?;
        }
    }
    if has_progress {
        emit(json!({"phase": "installing"}));
    }
    let replaced = selected.iter().try_for_each(|name| match steps.replacer {
        Some(replacer) => replacer(&stage.join(name), &directory.join(name)),
        None => replace(&stage.join(name), &directory.join(name)),
    });
    if replaced.is_err() {
        for name in FILES {
            if backup.join(name).exists() {
                let _ = fs::rename(backup.join(name), directory.join(name));
            } else {
                let _ = fs::remove_file(directory.join(name));
            }
        }
        return fail(t("保存失败，已恢复原规则库。", "Save failed; the previous rule data was restored."));
    }
    let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map(|age| age.as_secs()).unwrap_or(0);
    let _ = fs::write(directory.join(".geodata-updated-at"), seconds.to_string());
    let labels: Vec<&str> = selected.iter().map(|name| match *name { "geoip.dat" => "GeoIP", "geosite.dat" => "GeoSite", _ => "MMDB" }).collect();
    Ok(labels.join(&t("、", ", ")) + &t(" 已更新。下次启用代理时加载新规则库。", " updated. The new rule data loads next time the proxy starts."))
}

/// CLI: `geodata [--home DIR] [--check] [--json] [--files NAME…]`.
pub fn command(directory: &Path, check_only: bool, json_output: bool, files: &[String]) -> i32 {
    let print = |value: Value| say(&json_text(&value));
    let metadata = Metadata::default();
    let result = if check_only {
        check(directory, None, &metadata).map(|files| {
            if json_output { print(json!({"event": "checked", "files": files})) } else { say(&json_text(&Value::Object(files))) }
        })
    } else {
        let selected: Vec<&str> = if files.is_empty() { FILES.to_vec() } else { files.iter().map(String::as_str).collect() };
        let mut callback = |mut event: Map<String, Value>| {
            event.insert("event".into(), json!("progress"));
            print(Value::Object(event));
        };
        let progress: Option<&mut dyn FnMut(Map<String, Value>)> = if json_output { Some(&mut callback) } else { None };
        update(directory, UpdateSteps::default(), &selected, progress, &metadata).map(|message| {
            if json_output { print(json!({"event": "complete", "message": message})) } else { say(&message) }
        })
    };
    match result {
        Ok(()) => 0,
        Err(Error(message)) => {
            if json_output { print(json!({"event": "error", "message": message})) } else { say(&message) }
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const PRIVATE: [&str; 3] = ["config.yaml", ".api-secret", ".sub-url"];

    struct Home {
        directory: tempfile::TempDir,
        before: HashMap<String, Vec<u8>>,
        fresh: HashMap<&'static str, Vec<u8>>,
    }

    fn home() -> Home {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        fs::write(root.join(crate::paths::CORE_BINARY), "fixture").unwrap();
        for name in FILES {
            fs::write(root.join(name), format!("old {name}")).unwrap();
        }
        for name in PRIVATE {
            fs::write(root.join(name), format!("private {name}")).unwrap();
        }
        let before = fs::read_dir(root).unwrap().map(|entry| entry.unwrap()).map(|entry| (entry.file_name().to_string_lossy().into_owned(), fs::read(entry.path()).unwrap())).collect();
        let fresh = FILES.iter().map(|name| (*name, format!("new {name}").into_bytes())).collect();
        Home { directory, before, fresh }
    }

    impl Home {
        fn root(&self) -> &Path {
            self.directory.path()
        }
        fn serve(&self, url: &str, path: &Path) -> Result<()> {
            let name = url.rsplit('/').next().unwrap();
            match name.strip_suffix(".sha256sum") {
                Some(base) => fs::write(path, sha256_hex(&self.fresh[base])),
                None => fs::write(path, &self.fresh[name]),
            }
            .map_err(|_| Error("write".into()))
        }
        fn unchanged(&self) {
            for (name, content) in &self.before {
                assert_eq!(&fs::read(self.root().join(name)).unwrap(), content, "{name}");
            }
            let leftovers = fs::read_dir(self.root()).unwrap().filter(|entry| entry.as_ref().unwrap().file_name().to_string_lossy().starts_with(".geodata-update-")).count();
            assert_eq!(leftovers, 0);
        }
    }

    fn accept(_: &Path, _: &Path) -> Result<()> {
        Ok(())
    }

    fn run_update(home: &Home, download: &mut dyn FnMut(&str, &Path) -> Result<()>, validator: &dyn Fn(&Path, &Path) -> Result<()>) -> Result<String> {
        update(home.root(), UpdateSteps { download: Some(download), validator: Some(validator), replacer: None }, &FILES, None, &Metadata::default())
    }

    #[test]
    fn success_preserves_configuration_and_records_time() {
        std::env::remove_var("AMYFREE_LANG");
        let home = home();
        let result = run_update(&home, &mut |url, path| home.serve(url, path), &accept).unwrap();
        for name in FILES {
            assert_eq!(fs::read(home.root().join(name)).unwrap(), home.fresh[name]);
        }
        for name in PRIVATE {
            assert_eq!(fs::read(home.root().join(name)).unwrap(), home.before[name]);
        }
        assert!(result.contains("下次启用"));
        assert!(home.root().join(".geodata-updated-at").exists());
        assert!(run_update(&home, &mut |url, path| home.serve(url, path), &accept).unwrap().contains("最新"));
    }

    #[test]
    fn download_hash_manifest_and_format_failures_change_nothing() {
        let home = home();
        assert!(run_update(&home, &mut |url, path| if url.ends_with("geosite.dat") { Err(Error("offline".into())) } else { home.serve(url, path) }, &accept).is_err());
        home.unchanged();
        assert!(run_update(&home, &mut |url, path| {
            home.serve(url, path)?;
            if url.ends_with("geosite.dat") { fs::write(path, "corrupt").unwrap(); }
            Ok(())
        }, &accept).is_err());
        home.unchanged();
        assert!(run_update(&home, &mut |_, path| fs::write(path, "").map_err(|_| Error("".into())), &accept).is_err());
        home.unchanged();
        assert!(run_update(&home, &mut |url, path| home.serve(url, path), &|_, _| Err(Error("format".into()))).is_err());
        home.unchanged();
    }

    #[test]
    fn replace_failure_rolls_back_even_after_a_rename() {
        let home = home();
        let replacer = |source: &Path, target: &Path| {
            replace(source, target)?;
            if target.ends_with("geosite.dat") { Err(Error("disk failure".into())) } else { Ok(()) }
        };
        let mut download = |url: &str, path: &Path| home.serve(url, path);
        let steps = UpdateSteps { download: Some(&mut download), validator: Some(&accept), replacer: Some(&replacer) };
        assert!(update(home.root(), steps, &FILES, None, &Metadata::default()).is_err());
        home.unchanged();
    }

    #[test]
    fn concurrent_update_is_rejected() {
        let home = home();
        let _lock = support::try_lock(&home.root().join(".geodata-update.lock")).unwrap();
        assert!(run_update(&home, &mut |url, path| home.serve(url, path), &accept).is_err());
        drop(_lock);
        let _ = fs::remove_file(home.root().join(".geodata-update.lock"));
        home.unchanged();
    }

    #[test]
    fn selected_database_only_and_real_progress_events() {
        let home = home();
        let mut requested = Vec::new();
        let mut events = Vec::new();
        let mut download = |url: &str, path: &Path| {
            requested.push(url.to_string());
            home.serve(url, path)
        };
        let before = home.before.clone();
        let inspect = move |stage: &Path, _: &Path| {
            assert_eq!(fs::read(stage.join("geosite.dat")).unwrap(), before["geosite.dat"]);
            assert_eq!(fs::read(stage.join("country.mmdb")).unwrap(), before["country.mmdb"]);
            Ok(())
        };
        let mut progress = |event: Map<String, Value>| events.push(event);
        let steps = UpdateSteps { download: Some(&mut download), validator: Some(&inspect), replacer: None };
        update(home.root(), steps, &["geoip.dat"], Some(&mut progress), &Metadata::default()).unwrap();
        assert_eq!(requested.len(), 2);
        assert_eq!(fs::read(home.root().join("geoip.dat")).unwrap(), home.fresh["geoip.dat"]);
        for name in ["geosite.dat", "country.mmdb"] {
            assert_eq!(fs::read(home.root().join(name)).unwrap(), home.before[name]);
        }
        let downloaded = events.iter().find(|event| event.get("downloaded").and_then(Value::as_u64).unwrap_or(0) > 0).unwrap();
        assert_eq!(downloaded["downloaded"], home.fresh["geoip.dat"].len());
        assert_eq!(downloaded["total"], home.fresh["geoip.dat"].len());
        assert_eq!(events.last().unwrap()["phase"], "installing");
    }

    #[test]
    fn metadata_check_fetches_no_databases_and_changes_nothing() {
        let home = home();
        let mut requested = Vec::new();
        let mut download = |url: &str, path: &Path| {
            requested.push(url.to_string());
            home.serve(url, path)
        };
        let result = check(home.root(), Some(&mut download), &Metadata::default()).unwrap();
        assert!(result.values().all(|item| item["available"] == true));
        assert_eq!(requested.len(), 3);
        assert!(requested.iter().all(|url| url.ends_with(".sha256sum")));
        home.unchanged();
    }

    #[test]
    fn invalid_component_is_rejected() {
        let home = home();
        let steps = UpdateSteps::default();
        assert!(update(home.root(), steps, &["../other"], None, &Metadata::default()).is_err());
        home.unchanged();
    }

    #[test]
    fn revision_is_pinned_before_requesting_size() {
        let revision = "a".repeat(40);
        let pinned = DEFAULT_BASE.replace("@release", &format!("@{revision}"));
        let sha = revision.clone();
        let with_sha = Metadata { fetch: Box::new(move |_| json!({"sha": sha}).as_object().unwrap().clone()) };
        assert_eq!(with_sha.resolve_source(DEFAULT_BASE), pinned);
        let with_size = Metadata { fetch: Box::new(|_| json!({"size": 100}).as_object().unwrap().clone()) };
        assert_eq!(with_size.remote_size(&format!("{pinned}/geoip.dat")), 100);
        let empty = Metadata { fetch: Box::new(|_| Map::new()) };
        assert_eq!(empty.resolve_source(DEFAULT_BASE), DEFAULT_BASE);
        assert_eq!(empty.remote_size(&format!("{pinned}/geoip.dat")), 0);
    }

    #[test]
    fn redirect_body_size_cannot_become_download_size() {
        let headers = "HTTP/2 302\ncontent-length: 185\n\nHTTP/2 200\ntransfer-encoding: chunked\n\n";
        assert_eq!(response_size(headers), 0);
        assert_eq!(response_size(&headers.replace("transfer-encoding: chunked", "content-length: 100")), 100);
    }
}
