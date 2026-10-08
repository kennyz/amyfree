# Online Updates and curl Installation Implementation Plan

**Goal:** Add an in-app update flow and a single curl installation command, document both, and publish a signed release.

**Architecture:** Share a dependency-free macOS Bash installer between terminal installation and the application's updater. Resolve stable GitHub Releases, verify SHA-256 and the pinned Developer ID/team/bundle identity, stage alongside the destination, replace with rollback, and preserve the separate user configuration directory. The app checks in the background, asks before installation, stages while running, then hands replacement to a temporary helper and relaunches.

**Tech Stack:** AppKit/Foundation, macOS built-in curl/plutil/codesign/ditto, GitHub Releases.

1. Add `scripts/install.sh`: stable release discovery, exact version/asset validation, checked ZIP extraction, signature verification, same-directory replacement, backups, running-app handling and a no-launch option for testing.
2. Add `app/AppUpdater.swift` and menu integration. Check quietly on launch/daily; show manual check results and offer Download and Install. Keep existing proxy connections during app replacement and report failed installations through a log/dialog.
3. Include the installer in signed bundles; bump to 1.4.0. Update README with a curl command and the update menu location. Preserve the usage statement and signing/notarization disclosure.
4. Test version ordering, release response rejection, hash/signature failures, repeat installation, configuration preservation, waiting helper and rollback. Run existing regression suites and final packaged-app smoke tests.
5. Publish source, tag and signed Release; verify remote refs, artifact hashes and the actual public curl installation against an isolated target.

Installation uses no sudo, does not remove quarantine, and never sources a user-supplied remote endpoint. Tests must not change the user's active application or system proxy settings.
