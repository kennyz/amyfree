# Amyfree Development Guide

Reference for working on the source. For downloads and everyday use, see the [project home page](../README.md) ([中文](../README.zh-CN.md)).

A proxy setup for macOS: the **mihomo (Clash.Meta) core** plus a **pure AppKit menu bar control panel**.

- No interpreter at runtime: the menu bar app is native Swift / AppKit (built with `swiftc`, no Xcode project), and the runtime helper `amyfree-helper` is a Rust binary
- Rewrite in progress: the Rust core in `core/` will also power a cross-platform Tauri app for macOS and Windows (see `docs/plans/2026-10-17-rust-rewrite.md`)
- Broad subscription support, including the common **base64-encoded raw link** subscriptions (vless/vmess/ss/trojan)
- Full Clash YAML/JSON subscriptions; only nodes are imported, existing routing and DNS settings are left alone
- One-click on/off: starting the core takes over the macOS system proxy so browsers work immediately
- Optional TUN mode to capture all traffic
- Top-level "About Amyfree" shows the app version and the installed mihomo core version (even while the core is stopped); when a new version is found it shows the version number and links straight to the Upgrade Center
- Custom cat glyph (`app/CatGlyph.swift`): a front-facing cat head with the left ear tip cut at an angle (an "ear tip" marks a cared-for, free-roaming cat). In the menu bar the cat's eyes are open while the proxy is on and closed (asleep) while it is off, so the state is visible at a glance. The app icon draws the awake cat with a teal gradient; all icon sizes are generated at build time
- Native visual routing editor: China-direct, ad blocking, site and IP-range rules; validated on save, applied live, rolled back on failure
- Node status icons; latency and availability are checked every 3 minutes, with manual real-download speed tests
- Node management: add nodes from a link, QR code image or Clash YAML, and edit the current node; changes survive subscription updates
- Two-hop chain proxy: pick entry and exit nodes, validated on save, reloaded live and restored when turned off
- Compact two-level menu; the speed test window also shows TLS certificate expiry and warnings

---

## Quick Start

Menu bar app (Apple Silicon Mac with Xcode Command Line Tools and a Rust toolchain from [rustup.rs](https://rustup.rs)):

```bash
bash scripts/build-app.sh            # compile the app and amyfree-helper, package into build/
bash scripts/install-menubar.sh      # prepare core/rule data, install to ~/Applications and launch
```

Source builds do not bundle the core. The install script fills in the core, rule data and runtime scripts in `~/.config/mihomo`, keeping any existing subscription, secrets and config. On first use, import a subscription from the menu. Run the install script before double-clicking `build/Amyfree.app` directly.

To repair the runtime dependencies alone: `bash scripts/install-source-runtime.sh`.

For command-line-only debugging, follow the steps below. Do not run this alongside the menu bar install, or you will start two cores:

```bash
# 1. Fetch dependencies (core + rule data + config files)
bash scripts/fetch-deps.sh

# 2. Set the subscription URL (use single quotes; URLs often contain &)
./mihomo/mihomoctl.sh sub 'https://your-provider/subs/token'

# 3. Start and verify
cd mihomo && ./mihomoctl.sh start && ./mihomoctl.sh verify && cd ..

# 4. Route browsers through the proxy too
./mihomo/proxyctl.sh on
```

Advanced setups that need a standalone core LaunchAgent can still use `bash scripts/install-mihomo.sh`; the normal menu bar install does not need it.

---

## Directory Layout

```
.
├── app/                        Menu bar app (Swift / AppKit, no third-party dependencies)
│   ├── main.swift              Menu construction, status polling, action dispatch
│   ├── RoutingModel.swift      Rule model, input validation and config save transaction
│   ├── RoutingRules.swift      Visual routing window and live core reload
│   ├── LoginStartup.swift      macOS launch-at-login registration, status read-back and error handling
│   ├── NodeProbeModel.swift    3-minute check scheduling and speed test state
│   ├── NodeProbeClient.swift   Runs and cancels the background speed test helper
│   ├── NodeProbeWindow.swift   Node speed test and chain proxy windows
│   ├── NodeManagerWindow.swift Node management window (add/edit nodes), Form and Source modes
│   ├── NodeForm.swift          Node form field definitions and node dictionary read/write
│   ├── NodeImport.swift        QR code image decoding and node link extraction
│   ├── CatGlyph.swift          Cat glyph drawing (shared by the menu bar and app icon)
│   └── Info.plist              LSUIElement=true (menu bar only, no Dock icon)
├── core/                       Rust core library + amyfree-helper CLI (replaces the former Python scripts)
│   ├── src/yaml.rs             Safe, order-preserving YAML/JSON reader and node-file writer
│   ├── src/subscription.rs     Subscription parsing (Clash YAML/JSON, share links, base64), update transaction
│   ├── src/node_manager.rs     Custom and edited nodes, merged with the subscription into nodes.yaml
│   ├── src/chain.rs            Two-hop chain config, reload and rollback
│   ├── src/speed.rs            Isolated-session latency checks and real download speed tests
│   ├── src/cert.rs             TLS certificate expiry and trust status (OS trust store)
│   ├── src/geodata.rs          GeoIP/GeoSite/MMDB download, verification and replacement
│   ├── src/support.rs          Files, processes, locking, local HTTP
│   ├── src/bin/amyfree-helper.rs  Command-line entry point used by the app and scripts
│   └── tests/integration.rs    Real sockets, TLS server and mihomo core tests
├── mihomo/                     Runtime (scripts + config template; dependencies come from fetch-deps.sh)
│   ├── mihomoctl.sh            Core control: start/stop/restart/status/sub/refresh/nodes/verify/env
│   ├── proxyctl.sh             macOS system proxy switch: on/off/status/refresh
│   ├── tun.sh                  TUN mode switch (needs sudo)
│   ├── verify_node.sh          Hard node connectivity check (the exit IP must change)
│   └── config.template.yaml    Config template (config.yaml is generated at install)
├── scripts/
│   ├── fetch-deps.sh           Download the core and rule data (via mirrors reachable from China)
│   ├── refresh-geodata.sh      Update GeoIP/GeoSite/MMDB by hand (with rollback)
│   ├── build-app.sh            Compile and package the menu bar app
│   ├── generate-icon.swift     Draw every app icon size with AppKit (compiled together with app/CatGlyph.swift)
│   ├── test-routing.sh         Routing rule and save/rollback tests
│   ├── test-startup.sh         Launch-at-login toggle and error feedback regression tests
│   ├── install-mihomo.sh       Install the runtime + LaunchAgent
│   └── install-menubar.sh      Install the menu bar app
└── docs/GOTCHAS.md             ★ Lessons learned; read before changing code
```

---

## Architecture

### Data flow

```
Subscription URL ──curl──> amyfree-helper ──────────> providers/nodes.yaml
                                                            │
                                                 loaded by mihomo as type:file
                                                            │
                                                    ┌───────┴───────┐
                                              mixed-port:7890   API:9090
                                                    │               │
                                        system proxy/browsers   menu bar status polling
```

**Why the provider uses `type: file` instead of `type: http`:** most provider subscriptions are base64-encoded raw link lists, which mihomo cannot read, so they must be converted first. See item 5 in `docs/GOTCHAS.md`.

### Menu bar status refresh

The menu polls every 5 seconds. All network queries (exit IP, node latency, system proxy state) run on a **background queue** so the main thread never blocks and the menu stays responsive. Network queries are skipped while the core is not running.

### Environment variables

| Variable | Purpose |
|---|---|
| `MIHOMO_HOME` | Override the config directory (default `~/.config/mihomo`). For local debugging without touching the real config |
| `MIHOMO_VERSION` | Core version downloaded by `fetch-deps.sh` (default `v1.19.32`) |
| `GH_MIRROR` | GitHub mirror prefix (default `https://gh-proxy.com/`) |
| `GEODATA_BASE` | Rule data download source (default jsDelivr) |

Debugging the menu bar app locally:

```bash
bash scripts/fetch-deps.sh
MIHOMO_HOME="$PWD/mihomo" build/Amyfree.app/Contents/MacOS/Amyfree
```

---

## Common Commands

The Rust tests: `cargo test` (from the repository root).


```bash
cd mihomo

./mihomoctl.sh start            # start the core
./mihomoctl.sh stop             # stop it
./mihomoctl.sh status           # status + listening ports
./mihomoctl.sh restart
./mihomoctl.sh sub '<URL>'      # set the subscription URL (fetch + convert + restart)
./mihomoctl.sh sub              # show the current subscription URL
./mihomoctl.sh refresh          # re-fetch nodes from the current URL
./mihomoctl.sh test             # only test whether the subscription parses; writes nothing
./mihomoctl.sh test '<URL>'     # test a new URL without changing the subscription or nodes
./mihomoctl.sh nodes            # list nodes and latency
./mihomoctl.sh use 手动选择 '<node name>'
./mihomoctl.sh verify           # hard check: did the exit IP really change
./mihomoctl.sh log 50           # tail of the log
./mihomoctl.sh env              # print terminal proxy environment variables (eval-able)

./proxyctl.sh on|off|status     # system proxy (decides whether browsers use the proxy)
./proxyctl.sh refresh           # re-apply to the active network service after switching networks

sudo ./tun.sh on|off|status     # TUN mode
```

`手动选择` ("manual selection") is the name of the manual selector group in the config template.

## Visual Routing Editor

Choose "Routing Rules…" in the menu, or open Amyfree.app again, to bring up the settings window.

1. **Basic routing**: toggle China-direct and common ad blocking, and choose whether other traffic uses the automatic proxy, the manually selected proxy or a direct connection.
2. **Add rules**: paste a URL or type a domain, then choose Proxy, Direct or Block. Subdomains are included by default; exact domains and IPv4/IPv6 ranges are also supported.
3. **Reorder**: rules match top to bottom; move up/down to change priority. Custom rules take priority over basic routing; LAN traffic always stays direct.
4. **Save & Apply**: saved only after the core validates it. While running, the core reloads and the result is read back; while stopped, the rules apply on next start. If checking or applying fails, the draft is kept and the config restored.

"Restore Recommended" resets only the basic settings and keeps custom rules. "Revert to Last" loads the rules from before the last save; save again to revert. Existing advanced rules keep their original format and can be reordered or deleted; subscription, node and DNS settings outside routing are untouched. After saving, rule mode is used and new connections follow the new rules.

Routing and save transaction tests: `bash scripts/test-routing.sh`. The current Command Line Tools ship without XCTest, so the tests use a dependency-free Swift assertion runner.

References: [mihomo rule priority](https://wiki.metacubex.one/config/rules/), [config hot-reload API](https://wiki.metacubex.one/api/).

## Launch at Login

The "Launch at Login (Amyfree)" menu item controls whether Amyfree starts when you log in to macOS. The checkmark mirrors the actual registration state in macOS, and both enabling and disabling report the result. If macOS needs approval, the menu shows "needs approval" and can open the Login Items settings directly.

The toggle uses [Apple SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice) and does not depend on the core running, the subscription file or a standalone LaunchAgent. Old menu bar login entries are migrated at install time; the core's standalone LaunchAgent is still managed by `scripts/install-mihomo.sh`.

Regression tests: `bash scripts/test-startup.sh`. Check the state from an installed app: `~/Applications/Amyfree.app/Contents/MacOS/Amyfree --login-status`.

Subscription compatibility and rollback tests: `cargo test` (module `subscription`). They cover Clash YAML/JSON, links/base64, type preservation, bad input, test-only runs that write nothing, and config rollback after a failed start.

## Node Speed Test and Chain Proxy

"Tools → Node Speed Test…" shows status icons, latency, download speed and check time. Every **3 minutes** all nodes are checked for latency and availability, and this continues after the window is closed. A green check means available, a yellow clock slow, a red cross failed, a grey question mark not tested, and a blue icon testing; text labels are shown alongside.

"Test All Now" checks latency by hand. "Test Selected Download Speed" and "Test All Download Speeds" download a real **1 MB** sample per node and show the short average in **MB/s** (connection setup included). This is not converted from latency and is not a maximum-bandwidth estimate. Tests use an isolated proxy session, so they work while the main proxy is off, and they never change the current node, chain or system proxy. Overlapping checks pause during download tests.

"Chain Proxy…" lets you pick two different nodes as entry and exit, then enable and save. Traffic flows **device → entry → exit → website** and only affects the automatic/manual proxy policies; direct and block rules are kept. It uses [mihomo dialer-proxy](https://wiki.metacubex.one/config/proxies/dialer-proxy/). To keep the remote entry from receiving fake IPs, node server addresses use encrypted DNS while the chain is on; website and LAN DNS rules are kept, and the original node resolution settings come back when it is turned off.

Once on, the speed test list includes the whole chain. Subscription updates refresh the chain nodes' credentials, and if the entry or exit disappears, the chain turns off and the policy groups are restored. The core validates before saving; while running, the config is reloaded and read back, and failures restore the config. The chain is off by default and needs nodes chosen before it can be enabled.

Tests: `bash scripts/test-probe.sh` and `cargo test` (modules `chain` and `speed`, plus the real-core latency test in `core/tests/integration.rs`). Download samples come from [Cloudflare's public speed test endpoint](https://github.com/cloudflare/speedtest).

## Node Management

"Nodes & Subscription → Node Management…" (⌘E) opens with the current node selected, ready to edit; choose "+ New Node" to add one. Nodes can be edited in two ways, **Form** and **Source**, and switching converts the content both ways:

- **Form** shows the fields for the chosen protocol (vless/vmess/trojan/ss/hysteria2/tuic/http/socks5): name, server, port, credentials, TLS/SNI, transport and so on. Fields the form does not cover (such as `reality-opts` or `alpn`) are kept as they are.
- **Source** accepts one vless/vmess/ss/trojan share link, or one node's Clash YAML/JSON; switch to Form to see how it was parsed.

"Quick add" reads a node from a link (a node link on the clipboard is filled in automatically) or from a QR code image (decoded with CoreImage, no third-party dependency). The result fills in a new node for review before saving; an http(s) subscription URL is pointed to the subscription settings instead. Saving validates with the core first; while running, the core reloads and the node list is read back, and failures restore the original files.

The subscription's own nodes are stored in `providers/subscription.yaml` and manual changes in `custom-nodes.json` (`added` holds new nodes; `edited` holds edited subscription nodes keyed by their original name). The two are merged into `providers/nodes.yaml`, which the core loads. Edits still apply after subscription updates; an added node whose name now clashes with a subscription node is skipped for that update with a warning. Added nodes can be deleted, and edited subscription nodes can be restored to the subscription version; subscription nodes themselves cannot be deleted. The proxy can also start with only manual nodes and no subscription.

Tests: `cargo test` (module `node_manager`); form field mapping and QR decoding: `bash scripts/test-node-form.sh`.

## Compact Menu and Certificate Expiry

The top-level menu shows only the status line (merged with the current node), the proxy toggle, Select Node, Nodes & Subscription, Settings, Tools, About and Quit. The node list and "Test All Nodes Now" are under Select Node; Node Management and subscription editing/updating are under Nodes & Subscription; routing, chain proxy, system proxy, TUN, launch at login and Languages are under Settings; the node speed test, exit IP check, log, terminal, config folder and Upgrade Center are under Tools. Existing shortcuts are kept; Node Management is ⌘E.

The speed test window has a "Certificate" column, updated every 3 minutes alongside node checks. It shows the days remaining, with the exact expiry date on hover; certificates expiring within 30 days are yellow, and expired or not-yet-valid ones are red. Trust or hostname failures are marked separately, connection failures show "Can't confirm", and REALITY, non-TLS or not-yet-supported QUIC nodes are never misreported as expired. Chain rows show whichever of the entry and exit needs the most attention.

"Latency" uses mihomo's unified delay measurement: after a warm-up connection it measures the test site's response round trip, so first-time DNS, TCP and TLS handshake costs are not counted. It is neither ICMP ping nor MB/s download speed, and the test session stays independent of the main connection. If the core cannot reuse the connection for the second request, it may fall back to the first request's time. Reference: [mihomo unified delay](https://wiki.metacubex.one/config/general/).

The check reads the node server's leaf certificate using the configured SNI, sends no proxy credentials, and does not change the node's certificate verification options. Untrusted certificates are read during diagnosis only to show their validity period; the result still records the verification failure.

Certificate tests: `cargo test` (module `cert`, plus a local self-signed TLS server in `core/tests/integration.rs`). Menu structure check: `~/Applications/Amyfree.app/Contents/MacOS/Amyfree --menu-structure`.

---

## Platform and Limits

| Item | Notes |
|---|---|
| OS | macOS 13+ (developed on macOS 27 / Apple Silicon; for Intel, change `-target` in `build-app.sh`) |
| Core | mihomo v1.19.32; TUN needs a `with_gvisor` build |
| Runtime helper | `amyfree-helper` (Rust), installed into the config folder by the app; no Python or other interpreter is needed. YAML is read safely: only standard tags, size-limited aliases |
| TUN | **Requires root**; it takes over the default route, and non-root processes cannot create utun |
| System proxy | Only covers apps that honor the system proxy (browsers, most CLIs). Use TUN for apps that don't |

### Known behavior

- **`curl` ignores the macOS system proxy.** After `proxyctl.sh on`, a plain `curl` test still fails. That is curl's behavior and **does not mean the system proxy isn't working**. See item 7 in `docs/GOTCHAS.md` for how to verify.
- Turning on the system proxy writes `~/.config/mihomo/.proxy-state` to record which network services were changed, so they can be restored exactly; if that directory isn't writable, a temporary directory is used.
- Quitting the menu bar app turns off the system proxy but does **not** stop the proxy core.

---

## Development Notes

1. **Read `docs/GOTCHAS.md` before changing the config.** The DNS items are especially easy to break, and the symptoms show up far from the cause.
2. After changing `main.swift`, **re-run `build-app.sh` and `install-menubar.sh`**, or you will still be running the old binary.
3. To check that the binary really updated, insert an ASCII marker into the source, rebuild, then `grep -a marker binary` (Chinese UTF-8 literals can't be found this way, so don't rely on them).
4. `proxy-providers` has a local cache that **takes priority over the subscription URL**; after changing subscriptions, delete `providers/*.yaml` and restart.
5. This repository contains **no** binaries or credentials (the core and rule data come from `fetch-deps.sh`; the subscription URL and API secret are generated at install). Before committing, make sure `.sub-url`, `.api-secret` and `config.yaml` are not included.

## Release Builds

On Apple Silicon, run `bash scripts/build-release.sh` with a Developer ID Application certificate in the keychain. The script downloads and verifies pinned public dependencies, packages a DMG/ZIP that bundles the mihomo core, rule data and `amyfree-helper`, and writes a SHA-256 manifest.

With Apple notarization credentials configured, use `NOTARY_PROFILE=<keychain profile name> bash scripts/build-release.sh` to notarize and staple the ticket. Without a profile the build is only signed, and it does not claim to be notarized. The signing identity can also be set with `CODE_SIGN_IDENTITY`.

First-launch setup and upgrade-preservation regression tests: `bash scripts/test-runtime.sh`.

## Online Updates and the Installer

`scripts/install.sh` depends only on macOS system tools. It downloads from the stable release, verifies the SHA-256 and the pinned Developer ID/team/bundle identity, and replaces the app in a transaction that keeps the old copy until the new one is in place. By default it installs over an existing copy, or into `/Applications` / `~/Applications`, without sudo. In-app updates use the same script from the signed package: the update is staged in the background, then a temporary helper waits for the old process to exit, replaces the app and reopens it, without stopping the running proxy core. Failures are logged to `~/Library/Logs/Amyfree-update.log`.

Update model tests: `bash scripts/test-update.sh`. Installer regression: `python3 scripts/test-installer.py`. Full signed-package test: `python3 scripts/test-release.py`.

From a terminal you can choose the location and skip reopening: `bash scripts/install.sh --target /absolute/path/Amyfree.app --no-open`.

## Online Rule Data Updates

The Upgrade Center (see below) and `bash scripts/refresh-geodata.sh ~/.config/mihomo` use the same component. It downloads GeoIP/GeoSite/MMDB with their SHA-256 sums, then has the local core check each DAT/MMDB file; files are replaced only if all checks pass, and a failed save is rolled back automatically. Updates don't touch the subscription or config and don't interrupt current connections; they take effect the next time the proxy starts. `GEODATA_BASE` overrides the source, which must also serve a matching `.sha256sum` file for each database.

Regression tests: `cargo test` (module `geodata`).

## Unified Upgrade Center (1.5.0)

"Tools → Upgrade Center…" has four independent actions: Amyfree, GeoIP, GeoSite and MMDB. The app installer reports progress from the actual ZIP bytes received; the rule data component emits NDJSON byte progress, and supports `--check --json` to only check checksums, or `--json --files geoip.dat` to update a single file. Databases that weren't selected take part in format validation but are not replaced.

Check times and the per-item red-dot reminders are stored in UserDefaults. Checks run every 24 hours and keep their schedule across restarts and wake from sleep. Viewing the window doesn't clear a red dot; only completing that upgrade does, and a failed check keeps any known reminders.

Verification: `bash scripts/test-upgrade-center.sh`, `bash scripts/test-update.sh`, `cargo test`. Offscreen UI preview: `build/Amyfree.app/Contents/MacOS/Amyfree --render-upgrade-center build/upgrade-center.png`; add `--preview-progress` to see the progress styles.
