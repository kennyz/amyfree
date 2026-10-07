# Amyfree Signed Release Implementation Plan

**Goal:** Publish a concise project page and a Developer ID signed, self-contained Apple Silicon release.

**Architecture:** Bundle the proxy core, rule data and a private Python runtime. Initialize the user's runtime on first launch, preserving existing subscriptions, credentials and settings. Keep release signing separate from local ad-hoc builds.

**Tech Stack:** Swift/AppKit, Bash, Python, Apple codesign/notarytool, GitHub Releases.

1. Simplify `README.md` to advantages, download, usage and the requested acceptable-use statement; retain developer reference in `docs/DEVELOPMENT.md`.
2. Add `app/AppRuntime.swift` and startup initialization; route Python subprocesses through the bundled interpreter and certificate store. Test a fresh directory and an upgrade with existing private settings.
3. Add `scripts/build-release.sh` with pinned, checksum-verified core/Python downloads, third-party notices, inside-out Developer ID signing, DMG/ZIP packaging and checksums. Support optional notarization via a Keychain profile.
4. Run existing regression suites, fresh-install smoke checks and strict signature validation on the packaged artifact. Confirm the notarization state explicitly.
5. Push the commit, update the repository description, publish `v1.3.4` with downloadable artifacts, and verify remote commit, asset sizes and download hashes.

The release contains no personal subscription, API secret, generated configuration or node list. Production proxy settings must remain unchanged throughout packaging and tests.
