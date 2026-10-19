# Third-party components

Amyfree releases bundle the following independent components. The usage statement in the README does not alter their upstream licenses.

- **mihomo v1.19.32** — MetaCubeX, GPL-3.0. [Corresponding source](https://github.com/MetaCubeX/mihomo/tree/v1.19.32), [license](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/LICENSE). The upstream executable is redistributed without source modifications; only its macOS code signature is replaced for distribution. A copy of its GPL license accompanies the application. Corresponding source is included as a separate Release download.
- **Rule databases** — [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat), release commit `426f62e175218c1f1d0c909188fbff1746f88042`. The upstream documentation included in the application identifies its data sources and credits.

- **Rust dependencies** — The AppKit shell uses objc2/block2/dispatch2; runtime components use rustls, ureq, ring, serde_json, yaml-rust2 and other crates. Exact resolved versions, declared licenses and bundled notice texts are in `Contents/Resources/licenses/rust/` inside the app.

Releases from 1.7.0 onward do not bundle CPython, PyYAML or certifi. Some native windows remain implemented in Swift and are linked into the Rust executable.

Personal subscription URLs, proxy nodes, generated API credentials and user configuration are excluded from release packages.
