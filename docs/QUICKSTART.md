# Refresh Network — Quick Guide

**One-click macOS app to fix slow/stuck Wi-Fi.**

## What it does (in ~10 seconds)

1. **Disconnect Wi-Fi** — turns radio off, waits 5s
2. **Flush DNS cache** — `dscacheutil` + `mDNSResponder`
3. **Reconnect Wi-Fi** — turns radio on, waits for L2 association
4. **Verify** — checks IP, pings `1.1.1.1`, resolves `example.com` via DNS

One admin password prompt per run. macOS auto-handles DHCP during reconnect.

## Install

**Download:** [Releases page](https://github.com/mujtabarumi/mac-network-refresh/releases) → grab `Refresh-Network.app.zip` → unzip → drag to `/Applications`.

**First launch:** right-click → Open → Open (one-time Gatekeeper bypass — app is ad-hoc-signed, not Developer-ID).

## Use

- Spotlight (`⌘Space`) → "Refresh Network" → Enter
- Click **Start** → password → watch 4 steps tick green → click **OK**

## Hotkey (optional)

System Settings → Keyboard → Keyboard Shortcuts → **App Shortcuts** → assign a key (e.g. `⌃⌥⌘R`) to "Refresh Network".

## Final status meanings

| Message | What it means |
|---|---|
| ✅ "Connected and online — 192.168.x.x on en0" | Everything works |
| ❌ "Online but DNS isn't resolving" | Internet up, DNS broken |
| ❌ "Got an IP but no internet" | Router up, upstream down |
| ❌ "Completed with errors. No IP." | DHCP failed entirely |

## Build from source

```bash
git clone https://github.com/mujtabarumi/mac-network-refresh.git
cd mac-network-refresh
./build.sh         # needs Xcode Command Line Tools
open "Refresh Network.app"
```

Single Swift file (~530 lines), no dependencies, universal binary.

## Troubleshooting

- **"No Internet Connection" warning lingers in menu bar after run** — macOS recheck takes 30–60s on its own.
- **Failed runs leave a log** at `~/Library/Logs/RefreshNetwork-*.log` — share that if reporting bugs.
- **Password instead of Touch ID** — known limitation; needs a Developer-ID-signed helper tool to fix.

## Repo

**https://github.com/mujtabarumi/mac-network-refresh** · MIT licensed.
