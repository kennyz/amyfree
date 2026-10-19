# Amyfree

English | [简体中文](README.zh-CN.md)

A lightweight, minimal macOS menu bar proxy app built on the mihomo core.

## Highlights

- **Works out of the box**: runtime components are bundled — import a subscription, pick a node, connect with one click.
- **Native and light**: Native AppKit interface that lives in the menu bar and stays out of the Dock.
- **Subscription compatible**: supports Clash YAML/JSON and common link subscriptions.
- **Visible connections**: automatic node latency checks, real download speed tests and certificate expiry reminders.
- **Settings when you need them**: direct connections for China sites, ad blocking, custom routing rules, plus optional chain proxy and TUN mode.
- **Upgrade Center**: the app and its three rule databases upgrade separately, with real download progress, daily checks and a red-dot reminder.
- **English and Chinese**: switch the interface language in **Settings → Languages**.

## Download and use

Requires **macOS 13 or later on Apple Silicon (M-series chips)**.

1. Download `Amyfree-<version>-macOS-arm64.dmg` from [Releases](https://github.com/kennyz/amyfree/releases/latest).
2. Open the disk image, drag **Amyfree** into **Applications**, then open the app.
3. On first launch, enter your own lawful subscription URL, then save and update.
4. Click the cat icon in the menu bar, choose a node and turn on the proxy. To add your own node or edit the current one, use **Nodes & Subscription → Node Management…**.

The app is signed with an Apple Developer ID; see the release notes for its signing and notarization status. If macOS blocks it from opening, choose "Open Anyway" in System Settings → Privacy & Security. TUN mode requires administrator authorization.

### One-line install with curl

Run this in Terminal; no developer tools needed:

```bash
curl -fsSL https://raw.githubusercontent.com/kennyz/amyfree/main/scripts/install.sh | bash
```

It downloads the latest release, verifies the files and signature, then installs and opens the app. An existing installation is updated in place; new installs go to Applications, or `~/Applications` if that folder isn't writable.

### Online upgrades

Click the menu bar cat → **Tools → Upgrade Center…**. Amyfree, GeoIP, GeoSite and MMDB each have their own upgrade button and real download progress. Only the item being upgraded shows a fixed percentage bar; when the total size is unknown it shows the amount downloaded instead of an animated bar. Updates are checked automatically every 24 hours, and a red dot appears when one is available — it stays after restarting the app. The app reopens itself after upgrading; updated rule data takes effect the next time the proxy is turned on. If anything fails, the previous version and settings are kept. Users on `1.4.x` can upgrade first via the old menu "Tools → Check for Updates"; `1.3.4` and earlier need one update with the command above or the DMG.

This software does not provide subscriptions or proxy nodes. For development and building from source, see the [development guide](docs/DEVELOPMENT.md).

Building from source (requires Rust and Xcode Command Line Tools): clone the repository and run `bash scripts/build-app.sh && bash scripts/install-menubar.sh`. The install script downloads and installs the core and rule data automatically. Building the app alone does not install its runtime dependencies.

## Acceptable use

**This software is intended only for lawful and compliant internet access, study, research and work. Use for political activities or any illegal purpose is prohibited. Users must comply with the laws and regulations where they live and are responsible for their own use.**

Third-party components and their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
