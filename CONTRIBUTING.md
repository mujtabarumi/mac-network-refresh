# Contributing to Refresh Network

Thanks for your interest! This project is deliberately small — a single-file
native macOS utility with no third-party dependencies. The guiding principle is
**keep it boring**: one Swift file, no frameworks beyond SwiftUI + AppKit +
Foundation, no build system beyond a shell script.

## Project layout

| File | Purpose |
|------|---------|
| `RefreshNetwork.swift` | The entire app — SwiftUI views, `@MainActor` view model, and the `NSAppleScript`-driven privileged shell. |
| `make-icon.swift` | Renders the app icon master (`icon-master.png`) using AppKit + SF Symbols. Source of truth for the icon. |
| `build.sh` | Compiles a universal binary (`arm64` + `x86_64`), generates `AppIcon.icns`, bundles `Info.plist`, and ad-hoc-signs the app. |
| `Info.plist` | Bundle metadata (version, identifier, icon reference). |
| `docs/QUICKSTART.md` | 60-second install/use/troubleshoot guide. |

## Building

You need Xcode Command Line Tools (`xcode-select --install`). Then:

```bash
./build.sh
open "Refresh Network.app"
```

The build is fully deterministic — `build.sh` regenerates the icon and binary
from source every time. There is no Xcode project to open.

## Testing changes

There is no automated test suite (the app is one screen wrapping a shell
script). Verify changes manually:

1. `./build.sh` must succeed and produce a universal binary.
2. Launch the app and run a real refresh on a live Wi-Fi connection.
3. Confirm all four steps tick through and the final status is honest
   (connected / DNS-broken / no-internet / no-IP — see the README).
4. If you touched the icon, run `swift make-icon.swift` and eyeball
   `icon-master.png`.

When something goes wrong during a run, the app writes a diagnostic log to
`~/Library/Logs/RefreshNetwork-*.log` — attach it to bug reports.

## Code style

- Match the surrounding code: comment density, naming, and idiom.
- Keep everything in `RefreshNetwork.swift`. Don't add new source files or
  split into a Swift package unless there's a compelling reason.
- No third-party dependencies. Ever.
- Prefer clarity over cleverness — this is a utility friends will read.

## Scope & non-goals

Please don't open PRs for these — they're intentional non-goals:

- **Menu bar / background daemon mode** — it's a one-shot helper, by design.
- **A Wi-Fi network picker** — macOS auto-rejoins the SSID via keychain.
- **Cancel-mid-run** — interrupting the root shell cleanly isn't worth it for a
  ~10-second flow.

Good contributions: bug fixes, reliability improvements to the shell logic,
clearer status messages, accessibility, and **Touch ID support** (see the
README's "Touch ID notes" — this needs an `SMAppService` helper and is a
genuinely welcome, if larger, change).

## Pull requests

1. Fork and branch from `main`.
2. Keep the diff focused — one logical change per PR.
3. Make sure `./build.sh` is green and you've run the app once.
4. Describe what you changed and how you verified it.

## License

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
