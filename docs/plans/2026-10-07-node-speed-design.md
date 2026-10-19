# Subscription Node Checks and Download Speed Tests

## User experience

Menu nodes show a status icon and latency. "Node Speed Test…" opens a native list with status, latency, real download speed and last check time. It offers "Test Now" plus download tests for the selected node or all nodes. Latency and availability are checked automatically every 30 seconds; real download speed is only tested by hand. Grey means not tested or service paused, blue testing, green available, yellow slow and red failed, and each icon comes with a text label.

## Implementation

- `NodeProbeModel.swift`: scheduling, measurement state, batch re-entry protection, and discarding stale results after the subscription changes.
- `NodeProbeClient.swift`: measures latency through the provider node healthcheck API and loads the local node catalogue in the background; all network work runs in the background.
- `NodeProbeWindow.swift`: native table and manual actions, sharing one state with the menu.
- `mihomo/node_speed.py`: download tests start an isolated mihomo session pinned to the chosen node, download Cloudflare's 1 MB test data and return the real MB/s. They don't change the current node, routing or system proxy, and clean up temporary processes and files on exit.
- While the core is stopped, automatic checks use the isolated session without turning on the main proxy or system proxy. Missed runs aren't replayed after waking from sleep, and overlapping rounds are skipped while a check is still running.

## Verification

Tests for status thresholds, the 30-second schedule, re-entry and subscription changes; real node latency and download requests; isolated UI checks of the icons and manual actions; observe at least two automatic 30-second rounds. Confirm the main config, selected node and system proxy are unchanged before and after testing.

References: [mihomo provider node check API](https://wiki.metacubex.one/api/), [Cloudflare download speed endpoint](https://github.com/cloudflare/speedtest).

## Addendum: chain proxy

As a follow-up request, a two-hop entry/exit setting is provided using mihomo dialer-proxy. The proxy policy groups use the chain exit, while direct and block rules are kept. It is validated before enabling, reloaded and checked while running, and rolled back on failure. Single-node speed tests don't switch the main chain; the chain exit has its own speed test entry.
