# Gotchas: Pitfalls and Non-Obvious Findings

This file records non-obvious conclusions that were **actually verified** during development. Each item notes its evidence. Read the relevant items before changing related code.

---

## 1. DNS: a missing `direct-nameserver` causes a deadlock ★ the worst one

**Symptom:** after the core starts, the provider fails to download and the log shows

```
initial proxy provider nodes error: Get "https://<subscription domain>": net/http: TLS handshake timeout
[TCP] dial PROXY --> <subscription domain>:2096 error: dns resolve failed: context deadline exceeded
```

**Root cause:** with `respect-rules: true`, DNS queries are treated as ordinary traffic and follow the rules. Resolving the subscription/node domains then requires a working proxy, while connecting to the proxy requires resolving those domains first. **A chicken-and-egg deadlock.**

**Fix:** `dns.direct-nameserver` must be set; it resolves these domains over the direct path.

**How it was verified:**
- `respect-rules: false` + plain UDP `nameserver` → **still failed**
- The provider only downloaded successfully after adding `direct-nameserver`

---

## 2. Don't use DoH on 1.1.1.1 / 8.8.8.8

**Measured:** the development network **drops port 443 to these two IPs**.

```
curl https://1.1.1.1  → connection refused / timeout
```

So putting `https://1.1.1.1/dns-query` in `dns.fallback` makes DNS unusable as a whole (the log shows `all DNS requests failed`).

**Use instead:** plain UDP domestic DNS (`223.5.5.5`, `119.29.29.29`, `114.114.114.114`).

---

## 3. `respect-rules: true` also pushes domestic DNS through the proxy

**Log observed:**

```
[TCP] dial PROXY (match GeoSite/geolocation-!cn) --> www.google.com:443
         error: dns resolve failed: requesting https://1.1.1.1:443/dns-query: context deadline exceeded
```

With `respect-rules` on, even the DNS queries themselves follow the rules through the proxy, so domestic lookups get routed through the proxy as well, making them slower and more likely to time out.

**The current config uses `false`**, and relies on the `sniffer` to recover the real domain name so the node resolves it remotely.

---

## 4. `geo-auto-update` must be false

**Measured:** when `country.mmdb` is missing from the working directory, mihomo downloads it from GitHub and **hangs indefinitely**: after starting it stays unresponsive for a long time with no timeout message.

**Fix:**
- `geo-auto-update: false`
- The three rule data files (`geoip.dat` / `geosite.dat` / `country.mmdb`) **must be present in the working directory beforehand**
- Updates go through `scripts/refresh-geodata.sh` (jsDelivr mirror)

---

## 5. base64 subscriptions: mihomo can't read them directly; convert first

**Measured:** the provider's subscription returns

```
dmxlc3M6Ly8wMzljNzA1NS0...(one big base64 block)
```

which decodes to a list of raw `vless://...` links. mihomo's `proxy-providers` **does not support** this format.

**Fix:** `parse_sub.py` does "base64 decode → parse each protocol → write Clash YAML", and the result is loaded as `providers/nodes.yaml` through a `type: file` provider.

**Note:** the local `proxy-providers` cache **takes priority over** the subscription URL. After changing the subscription you must **delete `providers/*.yaml` and restart**; an API hot reload alone does not re-fetch the subscription. This pitfall actually caused "changed the subscription URL but still on the old nodes".

---

## 6. A false lead: counting `ss://`

While investigating the subscription format, `grep -c 'ss://'` counted 1 ss node, but the subscription actually contained **no** ss nodes.

**Why:** a node domain happened to contain the substring `ss://` (for example, in `exa**ss**le.example.com` the characters `ss` followed by the rest of the line matched across fields), so a `contains` check gives a false positive.

**Correct approach:** detect protocols with a **line-start match** (`line.startswith('ss://')`), not `contains`. The project's `parse_sub.py` splits on a line-start `scheme://`, so it is not affected.

---

## 7. `curl` does not read the macOS system proxy

**Measured:** after setting the system proxy with `networksetup`,

```
python3 urllib.getproxies()  → {'http': 'http://127.0.0.1:7890', 'https': ...}   ✓ picked up
curl https://www.google.com  → timeout (25s)                                      ✗ not picked up
```

**Conclusion:** **you cannot use `curl` to check whether the system proxy works**; that only tests whether a direct connection is reachable. curl only honors environment variables like `http_proxy` or an explicit `-x`.

**The right way to check the system proxy:**
```bash
scutil --proxy | grep -i enable
python3 -c "import urllib.request; print(urllib.request.getproxies())"
```
or just try a browser.

---

## 8. TUN mode requires root and fails inside a restricted sandbox

**Measured** (running as non-root, creating utun):

```
Start TUN listening error: configure tun interface: Connect: operation not permitted
```

Note that this is `operation not permitted` and **not** `permission denied`. This kind of error usually means a security policy (sandbox) blocked it, not just file permission bits.

**Conclusion:** TUN needs `sudo`. The menu bar app runs `tun.sh` with elevated rights via `osascript ... with administrator privileges`.

---

## 9. Non-root processes cannot listen on 80 / 443

**Measured:**
```
listen tcp 127.0.0.1:80:  bind: permission denied
listen tcp 127.0.0.1:443: bind: permission denied
listen tcp 127.0.0.1:7890: OK
listen tcp 127.0.0.1:1080: OK
```

So `mixed-port` uses 7890 (also the Clash ecosystem convention, and a common port for the macOS system proxy).

---

## 10. Full-width punctuation in scripts pollutes variable names

**Measured:** `grn "...（指向 $PROXY_PORT）"` under `set -u` fails with

```
PROXY_PORT）: unbound variable
```

**Why:** bash treated the full-width right parenthesis `）` as part of the variable name.

**Rule:** whenever a variable is immediately followed by a non-ASCII character, always write `${VAR}`.

(The whole repository was scanned before packaging to confirm there are no other cases; `scripts/check.sh` enforces this.)

---

## 11. Don't run a compiled binary after copying it by hand with `cp`

`codesign` modifies the Mach-O, so:

- The SHA256 of the build output and the binary inside the bundle **will always differ** (it doesn't mean the build failed)
- After `cp -R`, re-run `codesign --force --deep --sign -` and `xattr -dr com.apple.quarantine`

**The right way to check "did my change make it in":** insert an ASCII marker string into the source, rebuild, then `grep -a marker binary`. Chinese UTF-8 literals can't be found with `grep -a` (because of encoding), so don't rely on them.

---

## 12. `swiftc`'s default cache directory may not be writable

By default `swiftc` writes its module cache to `~/Library/Developer/...`, which fails in restricted environments.

**Fix:** set it explicitly
```bash
swiftc -O app/*.swift -o build/Amyfree \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" \
  -target arm64-apple-macosx13.0 -framework AppKit -framework ServiceManagement
```

---

## 13. Common API endpoints (handy for troubleshooting)

| Purpose | Endpoint |
|---|---|
| Version | `GET /version` |
| Group's current selection | `GET /proxies/<group name>` (field `now`) |
| **Provider node list** | `GET /providers/proxies/<provider name>` |
| Quick latency test | `GET /proxies/<node name>/delay?timeout=15000&url=...` |

**Note:** the node list lives under `/providers/proxies/...`, **not** `/proxies/<provider name>` (the latter returns `{"message":"Resource not found"}`). This mistake once left the menu bar node list permanently empty.

**Chinese group names:** `/proxies/手动选择` works when passed as-is (mihomo accepts both forms), but URL encoding is safer.

**Authentication:** once `secret` is set, requests must include `Authorization: Bearer <secret>`, or they get a 401.

---

## 14. `exclude-filter` on `proxy-providers` can catch real nodes

When filtering entries such as "expiry / traffic / website" by keyword, be careful: naming varies widely between providers, and a filter that is too broad also removes normal nodes. When the node count looks wrong, comment it out first.

---

## 15. `curl` must use `-L` when fetching the exit IP

**Measured:** `http://1.1.1.1/cdn-cgi/trace` returns a **301**. Without `-L` you get the redirect page, `grep '^ip='` naturally matches nothing, and `verify_node.sh` **falsely reports "node not in effect"**, while at the same moment `https://www.google.com`, `github.com` and `youtube.com` all return 200.

This false alarm is very misleading: the feature works, but the check script reports failure.
**Rule:** every curl used to fetch the exit IP / trace must include `-L`.

---

## 16. On a port conflict, an instance "starts but doesn't work at all"

**Measured scenario:** with the `~/.config/mihomo` instance already holding 7890/9090, starting another mihomo from a different directory brings the process up, and the log even shows "Mixed proxy listening", but:

- API requests return **401 Unauthorized** (they actually reach the old instance, which has a different secret)
- The exit IP results are wrong

**Extremely hard to diagnose**, because everything looks normal on the surface.

**Guard added:** `mihomoctl.sh start` checks whether 7890/9090 are in use before starting; if so, it reports a clear error and lists the processes holding them, instead of silently starting a useless instance.

**How to investigate:**
```bash
lsof -nP -iTCP:9090 -sTCP:LISTEN     # who holds the API port
lsof -nP -iTCP:7890 -sTCP:LISTEN     # who holds the proxy port
pgrep -fl "mihomo -d"                # how many instances in total
```
