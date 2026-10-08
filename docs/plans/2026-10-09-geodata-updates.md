# Geo Database Online Updates Implementation Plan

**Goal:** Add one-click online GeoIP, GeoSite and MMDB updates to signed and source installs.

**Architecture:** Download all three files to a temporary directory, verify upstream SHA-256 checksums and validate DAT/MMDB formats with the installed core before replacing any file. Lock overlapping updates and roll back replacement failures. Preserve configuration and current connections; new databases load on the next proxy start.

1. Share a Python updater through the existing CLI wrapper and the app menu.
2. Ship both helpers in source and Release installs; document Tools → Update Databases.
3. Test download/hash/format/replacement failures, private configuration preservation and real database parsing.
4. Publish signed 1.4.1 and verify remote artifact hashes and packaged helper/menu files.
