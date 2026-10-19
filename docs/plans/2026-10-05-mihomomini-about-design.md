# MihomoMini Name and About Menu

As requested, the app name, app bundle and executable are unified as MihomoMini; the original Bundle Identifier and runtime directory are kept so existing configurations keep working.

An "About MihomoMini…" item is added at the bottom of the menu. It uses an AppKit dialog to show the app version, build number and the installed mihomo core version. The app version is read from the bundle; the core version is read by running `mihomo -v` in the background, so it doesn't require the proxy service to be running. Not installed, unreadable and timed-out states are each shown.

The app version is updated to 1.1.0, build 2. The install script migrates the menu bar app from its old name, updates the launch path, and keeps the subscription and proxy configuration.

Verification: build, static checks, plist and strict code-signature checks, and confirming the installed bundle version and the new process. Automated UI reading of the menu bar app timed out, so the dialog was not visually checked.
