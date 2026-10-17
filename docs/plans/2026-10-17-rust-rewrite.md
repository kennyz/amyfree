# Rust Rewrite Plan

**Goal:** Rebuild Amyfree on Rust so it runs on macOS and Windows from one codebase, with no Python or other interpreter at runtime.

**Decisions (2026-10-17):** macOS and Windows; Tauri 2 for the app shell; migrate core first, then the UI. The last Swift version is the `swift-final` branch.

**Note on performance:** proxy traffic is handled by the mihomo core (Go), so the rewrite does not change proxy speed. The gains are one codebase across operating systems, no interpreter at runtime, and fast startup of the control panel and its helpers.

## Step 1 — Rust core and CLI (`core/`)

A library crate, `amyfree-core`, plus a command-line binary, `amyfree-helper`, that replaces every runtime Python script with the same commands and JSON output:

| Old script | New command |
|---|---|
| `subscription.py test\|fetch\|update\|save [URL]` | `amyfree-helper subscription …` |
| `node_speed.py --list\|--latency\|--node NAME` | `amyfree-helper node-speed …` |
| `chain_proxy.py status\|enable\|disable` | `amyfree-helper chain …` |
| `node_manager.py status\|get\|parse\|save\|delete` | `amyfree-helper node-manager …` |
| `geodata_update.py [--check] [--json] [--files …]` | `amyfree-helper geodata …` |
| `nodes.py PROVIDER API SECRET` | `amyfree-helper nodes …` |
| inline Python in `mihomoctl.sh start` | `amyfree-helper spawn-core …` |

- **YAML:** a safe, order-preserving loader built on the `yaml-rust2` event parser. Only standard tags are accepted (no object construction), aliases are size-limited, merge keys (`<<`) are supported, and plain `yes/no/on/off` resolve to booleans as PyYAML did. Values are `serde_json::Value` with `preserve_order`. A minimal YAML writer produces the node files.
- **Networking:** `ureq` for the local mihomo API and downloads (with byte progress); certificate checks use `rustls` with the operating system's trust store and read validity dates with `x509-parser`.
- **Processes:** isolated mihomo sessions for latency and download tests, cleaned up on exit; the main core is started detached (new session on Unix, detached process on Windows).
- **Tests:** the Python unit tests are ported to Rust tests.

The Swift app and shell scripts then call `amyfree-helper`; the release no longer bundles Python.

## Step 2 — Platform layer

Per-OS modules behind one interface: system proxy (macOS `networksetup`; Windows WinINet registry settings), TUN with administrator rights (macOS authorization prompt; Windows UAC and the wintun driver), launch at login, config paths (`~/.config/mihomo` on macOS, `%APPDATA%\Amyfree` on Windows), and replacing `mihomoctl.sh`/`proxyctl.sh`/`tun.sh` with Rust.

## Step 3 — Tauri 2 app

Tray menu with the current structure and the cat glyph (eyes open while the proxy is on). Windows for Node Management, Routing Rules, Node Speed Test, Chain Proxy and the Upgrade Center, built on the core library.

## Step 4 — Packaging and switch-over

Signed macOS DMG and Windows installer, the Tauri updater, migration of existing settings, then retire the Swift app.
