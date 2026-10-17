//! Platform-specific file names.

/// The mihomo core binary inside the config folder.
#[cfg(windows)]
pub const CORE_BINARY: &str = "mihomo.exe";
#[cfg(not(windows))]
pub const CORE_BINARY: &str = "mihomo";

/// curl ships with macOS and with Windows 10 (1803) and later.
#[cfg(windows)]
pub const CURL: &str = "curl.exe";
#[cfg(not(windows))]
pub const CURL: &str = "/usr/bin/curl";
