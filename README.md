# Refresh Network

A tiny native macOS SwiftUI app that fixes intermittently slow Wi-Fi with one click — disconnects, flushes DNS, reconnects, renews the DHCP lease, then verifies that the internet actually works.

No third-party dependencies. Single Swift file. Universal binary (Apple Silicon + Intel).

## Why

You know the situation: your Wi-Fi is technically connected, but everything is crawling. Toggling Wi-Fi off and on from the menu bar usually helps — but sometimes it doesn't, and you end up doing the full ritual in Terminal:

```bash
sudo networksetup -setairportpower en0 off
sleep 5
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
sudo networksetup -setairportpower en0 on
sudo ipconfig set en0 BOOTP
sleep 1
sudo ipconfig set en0 DHCP
ping -c 1 1.1.1.1
```

This app is that ritual, with one Cmd-Space "Refresh Network ↵" and one password prompt.

## What it does (5 steps, ~15 seconds total)

1. **Disconnect Wi-Fi** — `networksetup -setairportpower <iface> off`, then waits 5s for the Mac to fully release the interface.
2. **Flush DNS cache** — `dscacheutil -flushcache` + `killall -HUP mDNSResponder`.
3. **Reconnect Wi-Fi** — turns the radio back on, then polls `ifconfig <iface> | status: active` (up to 25s) for actual L2 association. Silently re-flushes DNS once the link is up.
4. **Renew DHCP lease** — release-then-renew on the active interface (`ipconfig set <iface> BOOTP` → `DHCP`), with one retry on transient failure.
5. **Verify connection** — waits up to 20s for an IP, then pings `1.1.1.1` and queries `example.com` via `dig` to confirm both reachability and DNS actually work.

The final status reflects the truth:
- ✅ **Connected and online — 192.168.1.91 on en0** — everything works
- ❌ **Online but DNS isn't resolving** — internet reachable, DNS broken
- ❌ **Got an IP but no internet** — router up, upstream down
- ❌ **Completed with errors. No IP** — failed to get a lease

## Screenshots

*(Add a screenshot of the running app here — drop a PNG into `docs/` and reference it.)*

## Requirements

- macOS 14 (Sonoma) or later
- Admin password (one prompt per run; see "Touch ID notes" below)

## Install

### Option A — download a release (recommended for friends)

1. Download the latest `Refresh Network.app.zip` from the [Releases](../../releases) page.
2. Unzip and drag **Refresh Network.app** into `/Applications`.
3. First launch: right-click the app → **Open** → **Open** (clears the unidentified-developer Gatekeeper prompt). Subsequent launches are normal double-clicks.

### Option B — build from source

```bash
git clone https://github.com/mujtabarumi/mac-network-refresh.git
cd mac-network-refresh
./build.sh
open "Refresh Network.app"
```

Requires Xcode Command Line Tools (`xcode-select --install`). The build script:
- Compiles arm64 and x86_64 binaries (universal)
- Bundles `Info.plist`
- Ad-hoc-signs the app so it launches without `kill -9`-on-arrival

## Usage

1. Open the app (Spotlight: `⌘Space` → "Refresh Network").
2. Click **Start**.
3. Enter your admin password.
4. Watch the five steps tick through.
5. Click **OK** when the final state appears.

For one-key triggering: System Settings → Keyboard → Keyboard Shortcuts → **App Shortcuts** → assign a hotkey to "Refresh Network".

## Architecture

- **`RefreshNetwork.swift`** — entire app: SwiftUI views, `@MainActor` view model, `NSAppleScript`-driven privileged shell. Single file, ~450 lines.
- **`build.sh`** — `swiftc -parse-as-library` build, `lipo` for universal binary, ad-hoc codesign.
- **`Info.plist`** — bundle metadata.

### How the progress UI stays live during a privileged shell

The whole network refresh is one batched bash script run via `NSAppleScript` with `do shell script ... with administrator privileges` — so there's exactly one auth prompt.

To get per-step progress without spawning a separate elevated process for each step, the bash script writes step markers (`STEP1=done`, `STATUS=Flushing DNS cache…`, etc.) to a temp file in `/tmp`. The Swift view model tails that file via a 150ms polling loop, parses new lines, and updates `@Published` state. Result: real progressive UI with a single auth prompt.

### Privileged operations

- `networksetup -setairportpower` — admin
- `killall -HUP mDNSResponder` — root (process owned by `_mdnsresponder`)
- `ipconfig set <iface> BOOTP|DHCP` — root

The non-privileged commands (`dscacheutil -flushcache`, `ifconfig`, `ping`, `dig`, reads) run inside the same admin shell anyway because everything is in one elevated `bash -c "…"`.

## Touch ID notes

The AppleScript admin dialog (`do shell script ... with administrator privileges`) on macOS 26 (Tahoe) appears to be hardcoded to password-only when invoked via `NSAppleScript`. The modern SecurityAgent dialog with Touch ID support requires either:

- A signed privileged helper tool installed via `SMAppService` (significant architectural addition: helper bundle, launchd plist, XPC), or
- A one-time `/etc/pam.d/sudo_local` change enabling `pam_tid.so` for `sudo` system-wide, with the app refactored to use `sudo` instead of `do shell script`

Neither has been implemented here. PRs welcome.

## Limitations / non-goals

- **No menu bar mode** — the app shows a window every run by design.
- **No background daemon** — it's a one-shot helper, not a network health monitor.
- **No cancel during run** — once the shell is running as root, interrupting it cleanly mid-step would require signal-forwarding to the child PID. Not worth it for a 15-second flow.
- **No Wi-Fi network picker / connector** — relies on macOS to auto-rejoin the same SSID after power cycle. (It does, via keychain.)

## Contributing

Pull requests welcome. Keep it boring: one file, no dependencies, no frameworks beyond SwiftUI + AppKit + Foundation.

## License

MIT — see [LICENSE](LICENSE).
