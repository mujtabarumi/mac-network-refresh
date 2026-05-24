// Refresh Network — SwiftUI macOS app
// Build: ./build.sh   →   Refresh Network.app
//
// Single auth prompt, then progressive UI updates as the privileged shell
// reports per-step progress via a temp log file that Swift tails.

import SwiftUI
import AppKit
import Foundation

// MARK: - Model

enum StepState {
    case pending, running, done, skipped, error

    /// Native SF Symbol — renders like a real macOS checkbox row.
    var systemImage: String {
        switch self {
        case .pending: return "square"
        case .running: return "square"             // overlaid with ProgressView
        case .done:    return "checkmark.square.fill"
        case .skipped: return "minus.square.fill"
        case .error:   return "xmark.square.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .secondary
        case .done:    return .accentColor
        case .skipped: return .secondary
        case .error:   return .red
        }
    }
}

struct Step: Identifiable {
    let id = UUID()
    let title: String
    var state: StepState = .pending
}

enum RunState {
    case idle, running, done, error, cancelled
}

// MARK: - View Model

@MainActor
final class RefreshViewModel: ObservableObject {
    @Published var steps: [Step] = [
        Step(title: "Disconnect Wi-Fi"),
        Step(title: "Flush DNS cache"),
        Step(title: "Reconnect Wi-Fi"),
        Step(title: "Verify connection"),
    ]
    @Published var status: String = "Ready. Click Start to refresh your network."
    @Published var runState: RunState = .idle
    @Published var progress: Double = 0

    private var detectedIP: String = ""
    private var targetInterface: String = ""
    private var reachable: Bool = false
    private var dnsOk: Bool = false

    func start() {
        guard runState == .idle else { return }
        runState = .running
        status = "Authenticating…"
        progress = 0
        for i in 0..<steps.count { steps[i].state = .pending }
        detectedIP = ""
        targetInterface = ""
        reachable = false
        dnsOk = false

        Task { await runRefresh() }
    }

    private func runRefresh() async {
        let logPath = "/tmp/refresh-network-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: logPath, contents: Data(), attributes: [.posixPermissions: 0o666])

        let script = Self.buildShellScript(logPath: logPath)

        // Start the progress tailer
        let tail = Task { [weak self] in
            await self?.tailProgress(file: logPath)
        }

        // Run the privileged shell in background (NSAppleScript → SecurityAgent
        // password dialog). On macOS 26 Tahoe this dialog is password-only;
        // Touch ID would require a Developer-ID-signed app + SMAppService helper,
        // which is out of scope for this single-file utility.
        let result = await Task.detached(priority: .userInitiated) {
            Self.runAdminAppleScript(shellScript: script)
        }.value

        tail.cancel()
        // Final sweep to catch the last few lines written between last poll and exit
        let finalLog = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        if !finalLog.isEmpty {
            processProgressChunk(finalLog, fromOffset: 0, allowReprocess: true)
        }

        if result.cancelled {
            status = "Authentication cancelled."
            runState = .cancelled
            try? FileManager.default.removeItem(atPath: logPath)
            return
        }
        if result.errored && detectedIP.isEmpty {
            status = "Could not run privileged refresh. Try again."
            runState = .error
            Self.persistDiagnosticLog(content: finalLog)
            try? FileManager.default.removeItem(atPath: logPath)
            return
        }

        finalize()
        // Keep a diagnostic copy when something went wrong so the user can share it.
        let anyError = steps.contains { $0.state == .error }
        if anyError {
            Self.persistDiagnosticLog(content: finalLog)
        }
        try? FileManager.default.removeItem(atPath: logPath)
    }

    /// Writes the final log to ~/Library/Logs/RefreshNetwork-<timestamp>.log
    /// when a run errors, so the user has something concrete to share.
    nonisolated private static func persistDiagnosticLog(content: String) {
        guard !content.isEmpty else { return }
        let fm = FileManager.default
        guard let home = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let logsDir = home.appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = logsDir.appendingPathComponent("RefreshNetwork-\(stamp).log")
        try? content.write(to: dest, atomically: true, encoding: .utf8)
    }

    private func finalize() {
        let ifaceSuffix = targetInterface.isEmpty ? "" : " on \(targetInterface)"
        if !detectedIP.isEmpty && reachable && dnsOk {
            status = "Connected and online — \(detectedIP)\(ifaceSuffix)"
            runState = .done
        } else if !detectedIP.isEmpty && reachable {
            status = "Online but DNS isn't resolving — \(detectedIP)\(ifaceSuffix)"
            runState = .error
        } else if !detectedIP.isEmpty {
            status = "Got an IP but no internet — \(detectedIP)\(ifaceSuffix)"
            runState = .error
        } else if steps.contains(where: { $0.state == .error }) {
            status = "Completed with errors. No IP."
            runState = .error
        } else {
            status = "Done."
            runState = .done
        }
        // Backfill anything still mid-flight to error. Without catching .running
        // here, a script that dies after STEP_N_START but before STEP_N=… leaves
        // the row stuck on the spinner forever — confusing UI.
        for i in 0..<steps.count where steps[i].state == .pending || steps[i].state == .running {
            steps[i].state = .error
        }
        progress = Double(steps.count)
    }

    private var lastByteOffset: Int = 0
    private var processedKeys: Set<String> = []

    private func tailProgress(file: String) async {
        lastByteOffset = 0
        processedKeys = []
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: file)) else { continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(lastByteOffset))
            } catch { continue }
            guard let data = try? handle.readToEnd(), !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { continue }
            processProgressChunk(chunk, fromOffset: lastByteOffset, allowReprocess: false)
        }
    }

    private func processProgressChunk(_ chunk: String, fromOffset: Int, allowReprocess: Bool) {
        // Only process up to the last newline (avoid partial-line reads)
        guard let lastNewline = chunk.lastIndex(of: "\n") else { return }
        let completePortion = String(chunk[..<lastNewline])
        let byteCount = completePortion.utf8.count + 1  // include the newline
        lastByteOffset = fromOffset + byteCount

        for line in completePortion.split(separator: "\n", omittingEmptySubsequences: true) {
            processProgressLine(String(line), allowReprocess: allowReprocess)
        }
    }

    private func processProgressLine(_ line: String, allowReprocess: Bool) {
        guard let eq = line.firstIndex(of: "=") else { return }
        let key = String(line[..<eq])
        let value = String(line[line.index(after: eq)...])

        // STATUS messages must NOT be deduped — they change throughout the run
        // and the user expects live updates. Step markers stay deduped so we
        // don't re-apply STEPx_START after STEPx has resolved.
        if !allowReprocess && key != "STATUS" {
            if processedKeys.contains(key) { return }
            processedKeys.insert(key)
        }

        switch key {
        case "STEP1_START": setStep(0, .running)
        case "STEP2_START": setStep(1, .running)
        case "STEP3_START": setStep(2, .running)
        case "STEP4_START": setStep(3, .running)
        case "STEP1": applyResult(0, value: value)
        case "STEP2": applyResult(1, value: value)
        case "STEP3": applyResult(2, value: value)
        case "STEP4": applyResult(3, value: value)
        case "STATUS":    status = value
        case "IP":        detectedIP = value
        case "TARGET":    targetInterface = value
        case "REACHABLE": reachable = (value == "yes")
        case "DNS_OK":    dnsOk = (value == "yes")
        default: break
        }
    }

    private func setStep(_ index: Int, _ state: StepState) {
        guard index < steps.count else { return }
        steps[index].state = state
    }

    private func applyResult(_ index: Int, value: String) {
        guard index < steps.count else { return }
        let state: StepState
        switch value {
        case "done":    state = .done
        case "skipped": state = .skipped
        case "error":   state = .error
        default:        state = .error
        }
        steps[index].state = state
        let completed = steps.prefix(through: index).filter { $0.state == .done || $0.state == .skipped }.count
        progress = max(progress, Double(completed))
    }

    // MARK: - Shell

    private static func buildShellScript(logPath: String) -> String {
        // logPath is a /tmp path with no quotes — safe to interpolate raw.
        // `set +e` is intentional: every command is wrapped in `if` guards so
        // partial failures don't abort the script — we still want to show the
        // user which steps succeeded.
        return """
set +e
LOG="\(logPath)"
emit() { printf '%s\\n' "$1" >> "$LOG"; }

# Diagnostic: emit script exit reason so we can tell completion from an early death.
# A successful end emits SCRIPT_END=ok. A trap-fired exit emits the bash exit code.
trap 'emit "SCRIPT_END=trap_$?"' EXIT
trap 'emit "SCRIPT_END=signal_INT"; exit 130' INT
trap 'emit "SCRIPT_END=signal_TERM"; exit 143' TERM

emit "STATUS=Detecting interfaces…"
WIFI=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')
[ -z "$WIFI" ] && WIFI=en0
WIFI_WAS_ON="no"
networksetup -getairportpower "$WIFI" 2>/dev/null | grep -q ': On' && WIFI_WAS_ON="yes"
ROUTE=$(route get default 2>/dev/null | awk '/interface:/{print $2}')

# Step 1: Disconnect Wi-Fi and let macOS fully release the interface
emit "STEP1_START=1"
if [ "$WIFI_WAS_ON" = "yes" ]; then
  emit "STATUS=Turning Wi-Fi off…"
  if networksetup -setairportpower "$WIFI" off 2>/dev/null; then
    emit "STATUS=Waiting 5s to let the Mac fully release the interface…"
    sleep 5
    emit "STEP1=done"
  else
    emit "STEP1=error"
  fi
else
  emit "STEP1=skipped"
fi

# Step 2: Flush DNS caches (first pass — clear stale entries from before)
emit "STEP2_START=1"
emit "STATUS=Flushing DNS cache…"
dscacheutil -flushcache >/dev/null 2>&1
killall -HUP mDNSResponder 2>/dev/null
emit "STEP2=done"

# Step 3: Reconnect Wi-Fi and wait for actual L2 association
# Detection: `ifconfig <iface> status: active` (works without Location perms;
# `networksetup -getairportnetwork` would need Location Services since 14.4).
WIFI_CONNECTED="no"
emit "STEP3_START=1"
if [ "$WIFI_WAS_ON" = "yes" ]; then
  emit "STATUS=Turning Wi-Fi on…"
  if networksetup -setairportpower "$WIFI" on 2>/dev/null; then
    emit "STATUS=Waiting for Wi-Fi to associate with a network…"
    for i in $(seq 1 25); do
      LINK_STATUS=$(ifconfig "$WIFI" 2>/dev/null | awk '/status:/{print $2}')
      if [ "$LINK_STATUS" = "active" ]; then
        WIFI_CONNECTED="yes"
        break
      fi
      sleep 1
    done
    if [ "$WIFI_CONNECTED" = "yes" ]; then
      # Second-pass DNS flush — drop any answers cached during the brief
      # interval between Wi-Fi-on and first user-visible network use.
      dscacheutil -flushcache >/dev/null 2>&1
      killall -HUP mDNSResponder 2>/dev/null
      emit "STEP3=done"
    else
      emit "STEP3=error"
    fi
  else
    emit "STEP3=error"
  fi
else
  # Wi-Fi was already off — nothing to reconnect
  emit "STEP3=skipped"
fi

# Decide which interface to verify against.
# Priority: current default route → freshly-reconnected Wi-Fi → nothing.
# (Wi-Fi reconnection in step 3 already triggers DHCP automatically — no
#  explicit renew needed. Cycling Wi-Fi is the actual fix; DHCP renew was
#  cargo-cult and caused stale "No Internet" badges via the BOOTP release.)
TARGET=""
NEW_ROUTE=$(route get default 2>/dev/null | awk '/interface:/{print $2}')
if [ -n "$NEW_ROUTE" ]; then
  TARGET="$NEW_ROUTE"
elif [ "$WIFI_CONNECTED" = "yes" ]; then
  TARGET="$WIFI"
fi

# Step 4: Verify — IP + actual internet reachability + DNS resolution
emit "STEP4_START=1"
IP=""
if [ -n "$TARGET" ]; then
  emit "STATUS=Waiting for IP on $TARGET…"
  for i in $(seq 1 20); do
    IP=$(ipconfig getifaddr "$TARGET" 2>/dev/null)
    [ -n "$IP" ] && break
    sleep 1
  done
fi

REACHABLE="no"
DNS_OK="no"
if [ -n "$IP" ]; then
  emit "STATUS=Testing internet reachability…"
  # 1 packet, 2s wait, quiet — Cloudflare DNS as ICMP target
  if /sbin/ping -c 1 -W 2000 -q 1.1.1.1 >/dev/null 2>&1; then
    REACHABLE="yes"
  fi
  # DNS resolution check — bypass system resolver, query 1.1.1.1 directly
  if /usr/bin/dig @1.1.1.1 +short +time=2 +tries=1 example.com >/dev/null 2>&1; then
    DNS_OK="yes"
  fi
fi

emit "IP=$IP"
emit "TARGET=$TARGET"
emit "REACHABLE=$REACHABLE"
emit "DNS_OK=$DNS_OK"

if [ -n "$IP" ] && [ "$REACHABLE" = "yes" ] && [ "$DNS_OK" = "yes" ]; then
  emit "STEP4=done"
else
  # Got IP but no reachability OR no DNS OR no IP at all — mark as error
  # so the final status surfaces the partial-success honestly.
  emit "STEP4=error"
fi
emit "SCRIPT_END=ok"
"""
    }

    nonisolated static func runAdminAppleScript(shellScript: String) -> (output: String, cancelled: Bool, errored: Bool) {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Wrap in `with timeout` — default AppleScript timeout is 120s,
        // which can bite if step 3's association poll + DHCP + verify all run long.
        // 180s is a generous upper bound for the full flow.
        let source = """
        with timeout of 180 seconds
            do shell script "\(escaped)" with administrator privileges
        end timeout
        """

        guard let script = NSAppleScript(source: source) else {
            return ("", false, true)
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 {
                return ("", true, false)
            }
            return ("", false, true)
        }
        return (result.stringValue ?? "", false, false)
    }

}

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = RefreshViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "wifi.router.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                Text("Refresh Network")
                    .font(.title2.bold())
                Spacer()
            }

            ProgressView(value: vm.progress, total: Double(vm.steps.count))
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(.easeInOut(duration: 0.3), value: vm.progress)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(vm.steps) { step in
                    HStack(spacing: 12) {
                        Image(systemName: step.state.systemImage)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(step.state.tint)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 22, height: 22)
                            .animation(.easeInOut(duration: 0.2), value: step.state)

                        Text(step.title)
                            .font(.body)
                            .foregroundStyle(step.state == .pending ? .secondary : .primary)

                        if step.state == .running {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.leading, 4)
                        }

                        Spacer()
                    }
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 0)

            Text(vm.status)
                .foregroundColor(.secondary)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(actionLabel) { handleAction() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.runState == .running)
            }
        }
        .padding(24)
        .frame(width: 460, height: 420)
    }

    private var actionLabel: String {
        switch vm.runState {
        case .idle:                      return "Start"
        case .running:                   return "Running…"
        case .done, .error, .cancelled:  return "OK"
        }
    }

    private func handleAction() {
        switch vm.runState {
        case .idle:                      vm.start()
        case .done, .error, .cancelled:  NSApp.terminate(nil)
        case .running:                   break
        }
    }
}

// MARK: - App entry

@main
struct RefreshNetworkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Refresh Network") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
