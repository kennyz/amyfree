# Mimio Routing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the app to Mimio and provide native routing settings that don't require editing YAML.

**Architecture:** A Foundation model reads the existing rules, keeping advanced rules and the rest of the config intact. An AppKit window provides the basic toggles, the rule list, adding/editing and reordering. Saving is validated by the core, written transactionally, reloaded through the API while running, and rolled back on failure.

**Tech Stack:** Swift / Foundation / AppKit / mihomo REST API, no third-party dependencies.

---

## 1. Rule model and save transaction

- New `app/RoutingModel.swift`: parses only the YAML rules list format used by the project, recognizing basic rules, domains and IP ranges; advanced rules are kept verbatim.
- Input supports extracting the domain from a URL, subdomain/exact matching, and IPv4/IPv6 CIDR; control characters and separator injection are rejected.
- Saving changes only rules and mode. After validation it updates config.yaml, .run-config.yaml and the non-TUN backup when present; config conflicts, validation failures or apply failures leave no partial changes.
- `tests/main.swift` uses a native Swift assertion runner to check priority, config preservation, validation failures, conflicts and rollback (the local CLT has no XCTest); the real core is used to check the generated config and hot reload.

## 2. Native visual window

- New `app/RoutingRules.swift`, with a menu entry in `main.swift` and a window entry when the app is opened again.
- One window: basic settings, a priority-ordered rule list, add/edit/delete/move up/move down, recommended settings, revert to last, and save & apply.
- New rules use a native form with the three common actions: Proxy, Direct, Block; advanced rules are shown as read-only entries.
- Shows unsaved, saving, failed and succeeded states, prompts when closing with unsaved changes, and every button is keyboard accessible.

## 3. Name and delivery

- Update Info.plist, the build/install scripts and the README; migrate MihomoMini and earlier names while keeping the config directory and Bundle Identifier.
- Version 1.2.0, build 4; keep the M shield icon.
- Build, static checks and signature verification; install and launch Mimio, and check the form, saving and reloading in the native UI.

The workspace has no Git metadata, so the work is done in the current directory without commits or worktrees.

References: [rule format and priority](https://wiki.metacubex.one/config/rules/), [config reload API](https://wiki.metacubex.one/api/).
