# Unified Upgrade Center Implementation Plan

**Goal:** Provide a single native update window with independently clickable application, GeoIP, GeoSite and MMDB updates, real download progress, daily detection and persistent red-dot reminders.

**Architecture:** A main-thread coordinator owns four row states and persists daily checks/available-update flags. Application staging reports real ZIP bytes against GitHub asset size; the Geo helper emits NDJSON progress and supports metadata-only checks and selected database updates. Existing signature validation, format validation and rollback remain in place. Badge state updates the menu-bar icon, menu entry and individual rows and clears only after the relevant update succeeds.

**UI:** One 620-point AppKit window, four compact rows with state text, bytes/percentage, progress bars and individual action buttons. A shared Check Updates button and last-check time sit above the rows. Downloads and checks run off the main thread; failures appear inline and are retryable. Application installation confirms restart; databases load on the next proxy start.

1. Extend release metadata, schedule/state models and process streaming.
2. Extend Geo updater with selected-file updates, lightweight checksum checks and real byte progress while preserving transactions.
3. Add coordinator/window and replace the old menu actions with Upgrade Center; check every 24 hours across launches and wake.
4. Test schedule boundaries, persisted badges, progress parsing, selected-file rollback and check-only behavior. Run packaged regression tests and visually inspect the new window.
5. Publish signed 1.5.0, verify remote assets, update the local installation while preserving configuration, and inspect the installed window.
