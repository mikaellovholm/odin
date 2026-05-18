#if os(macOS)
import SwiftTerm
import Foundation

/// A completed (or failed) background task surfaced to the user via a banner
/// above the terminal. Created by `BackgroundClaudeRunner.finish` and pushed
/// into the matching `LocalTerminalViewModel.pendingNotifications`.
struct BackgroundNotification: Identifiable, Equatable {
    enum Kind: Equatable { case success, failure }

    let id: UUID = UUID()
    let taskId: String
    let kind: Kind
    let preview: String
}

@Observable
@MainActor
final class LocalTerminalViewModel {
    enum State: Equatable {
        case notStarted
        case starting
        case running
        case exited(code: Int32?)
        case error(String)
    }

    var state: State = .notStarted
    var workingDirectory: String = NSHomeDirectory()
    /// Claude is currently processing (`UserPromptSubmit` fired, `Stop` has not
    /// yet). Drives the yellow pulsing dot.
    var isActive: Bool = false
    /// Claude finished a turn without acknowledgement. Set when the hook-driven
    /// state transitions from `working` to `idle`; cleared by `acknowledge()`.
    var didFinish: Bool = false
    /// Claude raised a `Notification` (permission prompt, idle reminder, etc).
    /// Drives the green "needs attention" dot. Cleared by `acknowledge()`.
    var awaitingInput: Bool = false
    var pendingNotifications: [BackgroundNotification] = []

    private(set) var sessionId: String?
    /// Path of the per-launch .mcp.json written by `writeMCPConfig`. Deleted
    /// when the session terminates or restarts to prevent $TMPDIR accumulation.
    private var mcpConfigPath: String?

    /// Path of the per-session state file written by the `odin-status.sh` hook
    /// and watched by `statusFileSource`. Cleaned up on teardown.
    private var statusFilePath: String?
    private var statusFileSource: DispatchSourceFileSystemObject?

    /// Timestamp of the last byte received from the child PTY. Used by the
    /// idle-heartbeat timer to detect Claude blocking on a slash-command menu
    /// or other interactive prompt that doesn't fire the `Notification` hook.
    private var lastDataReceivedAt: Date?
    private var heartbeatTimer: DispatchSourceTimer?

    /// How long PTY output must be silent while `isActive` is true before we
    /// promote the session to `awaitingInput`. 2s is short enough to feel
    /// responsive but long enough to not trip on normal streaming pauses.
    private static let heartbeatIdleThreshold: TimeInterval = 2.0

    private var process: LocalProcess?
    private var bridge: ProcessBridge?
    private(set) weak var terminalView: TerminalView?

    func setTerminalView(_ tv: TerminalView) {
        terminalView = tv
    }

    func startClaude() {
        guard let claudePath = ClaudePath.resolve() else {
            state = .error("claude CLI not found.\nInstall with: npm install -g @anthropic-ai/claude-code")
            return
        }

        // Per-launch identity. Shared between the X-Session-Id MCP header
        // (lets the server route background task completions back here) and
        // the ODIN_SESSION_ID env var (read by the UserPromptSubmit, Stop,
        // Notification, and SessionEnd hooks).
        let sessionId = "s-" + UUID().uuidString.prefix(8).lowercased()
        self.sessionId = sessionId
        OdinSessionRegistry.shared.register(self, for: sessionId)
        startStatusWatcher(sessionId: sessionId)
        startHeartbeat()

        var args: [String] = []
        if let mcpURL = OdinMCPServer.shared.mcpURL,
           let configPath = Self.writeMCPConfig(url: mcpURL, sessionId: sessionId) {
            args.append(contentsOf: ["--mcp-config", configPath])
            mcpConfigPath = configPath
        }

        let bridge = ProcessBridge(
            onData: { [weak self] slice in
                self?.terminalView?.feed(byteArray: slice)
                self?.noteDataReceived()
            },
            onTerminated: { [weak self] exitCode in
                self?.state = .exited(code: exitCode)
                self?.process = nil
            },
            onGetWindowSize: { [weak self] in
                guard let tv = self?.terminalView else {
                    return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
                }
                let terminal = tv.getTerminal()
                return winsize(
                    ws_row: UInt16(clamping: max(terminal.rows, 1)),
                    ws_col: UInt16(clamping: max(terminal.cols, 1)),
                    ws_xpixel: UInt16(clamping: Int(tv.frame.width)),
                    ws_ypixel: UInt16(clamping: Int(tv.frame.height))
                )
            }
        )
        self.bridge = bridge

        let proc = LocalProcess(delegate: bridge, dispatchQueue: .main)
        process = proc
        proc.startProcess(
            executable: claudePath,
            args: args,
            environment: Self.buildEnvironment(sessionId: sessionId),
            execName: nil,
            currentDirectory: workingDirectory
        )
        state = .running
    }

    func sendData(_ data: ArraySlice<UInt8>) {
        process?.send(data: data)
    }

    func resizeTerminal(cols: Int, rows: Int) {
        guard let process, process.running else { return }
        let safeCols = UInt16(clamping: max(cols, 1))
        let safeRows = UInt16(clamping: max(rows, 1))
        var size = winsize(ws_row: safeRows, ws_col: safeCols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    /// Acknowledge the "just finished" yellow-stable dot so the sidebar
    /// indicator falls back to grey. Called when the user clicks the session
    /// row or when the session is the one currently being viewed.
    ///
    /// `awaitingInput` is deliberately *not* cleared here: that flag means
    /// "Claude is blocked on user input", which is only resolved by the user
    /// actually submitting (UserPromptSubmit hook → state="working" → flag
    /// clears via `applyHookState`). Clicking the row to look at the prompt
    /// is not the same as responding to it.
    func acknowledge() {
        didFinish = false
    }

    func terminate() {
        tearDownCurrentSession()
        process?.terminate()
    }

    func restart() {
        tearDownCurrentSession()
        pendingNotifications.removeAll()
        process = nil
        bridge = nil
        isActive = false
        didFinish = false
        awaitingInput = false
        terminalView?.getTerminal().resetToInitialState()
        startClaude()
    }

    /// Unregisters the session from the registry and cleans up files that were
    /// written for the session: the per-launch .mcp.json in $TMPDIR, the
    /// pending-notification file in ~/.claude/odin-pending/, and the
    /// hook-driven state file in ~/.claude/odin-status/.
    private func tearDownCurrentSession() {
        stopStatusWatcher()
        stopHeartbeat()
        if let oldId = sessionId {
            OdinSessionRegistry.shared.unregister(oldId)
            let pendingFile = NSHomeDirectory() + "/.claude/odin-pending/\(oldId).txt"
            try? FileManager.default.removeItem(atPath: pendingFile)
            let statusFile = NSHomeDirectory() + "/.claude/odin-status/\(oldId).state"
            try? FileManager.default.removeItem(atPath: statusFile)
        }
        sessionId = nil
        if let path = mcpConfigPath {
            try? FileManager.default.removeItem(atPath: path)
            mcpConfigPath = nil
        }
    }

    // MARK: - Hook-driven status

    /// Pre-creates the per-session state file and starts a `DispatchSource`
    /// watcher on it. The `odin-status.sh` hook (registered by
    /// `OdinHookInstaller`) writes one of `working`, `idle`, `awaiting-input`
    /// into this file on each Claude lifecycle event; we drive `isActive`,
    /// `awaitingInput`, and `didFinish` from those writes.
    private func startStatusWatcher(sessionId: String) {
        let dir = NSHomeDirectory() + "/.claude/odin-status"
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let path = dir + "/\(sessionId).state"
        // Pre-create with empty content so we have a stable inode to watch.
        // Subsequent hook writes are truncate-and-overwrite (same inode), so a
        // single file-level kqueue source catches every state transition.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[Odin] failed to open status file for watching: \(path)")
            return
        }
        statusFilePath = path
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.readStatusFile()
        }
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
        statusFileSource = src
        // Pick up any state already written (e.g. if a hook fired between
        // pre-create and watcher attach).
        readStatusFile()
    }

    private func stopStatusWatcher() {
        statusFileSource?.cancel()
        statusFileSource = nil
        statusFilePath = nil
    }

    // MARK: - PTY heartbeat

    /// Records that bytes arrived from the child PTY. Resumes "working"
    /// presentation if a previous silence promoted the session to
    /// `awaitingInput` via the heartbeat.
    private func noteDataReceived() {
        lastDataReceivedAt = Date()
        // If the heartbeat had promoted us to awaiting-input but real output
        // is flowing again, demote back to active.
        if awaitingInput && isActive {
            awaitingInput = false
        }
    }

    /// Ticks every 500ms while a session is running. When `isActive` is true
    /// but no PTY bytes have arrived for `heartbeatIdleThreshold`, promote the
    /// session to `awaitingInput`. This catches slash-command menus and other
    /// interactive prompts that don't fire Claude Code's `Notification` hook
    /// — the dot turns green even though Claude considers itself mid-turn.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        lastDataReceivedAt = nil
    }

    private func checkHeartbeat() {
        guard isActive, !awaitingInput,
              let last = lastDataReceivedAt,
              Date().timeIntervalSince(last) >= Self.heartbeatIdleThreshold
        else { return }
        awaitingInput = true
    }

    private func readStatusFile() {
        guard let path = statusFilePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8) else { return }
        let state = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isEmpty else { return }
        applyHookState(state)
    }

    private func applyHookState(_ hookState: String) {
        let wasActive = isActive
        switch hookState {
        case "working":
            isActive = true
            awaitingInput = false
        case "idle":
            isActive = false
            awaitingInput = false
            if wasActive { didFinish = true }
        case "awaiting-input":
            // Claude is still mid-turn, just blocked on user input — keep
            // `isActive` true so that when the user responds and bytes resume
            // flowing, `noteDataReceived` can clear `awaitingInput` (it gates
            // the demotion on `isActive` so unrelated stray bytes don't trip it).
            awaitingInput = true
        default:
            break
        }
    }

    // MARK: - Background notifications

    func addBackgroundNotification(_ note: BackgroundNotification) {
        pendingNotifications.append(note)
    }

    func dismissBackgroundNotification(id: UUID) {
        pendingNotifications.removeAll { $0.id == id }
    }

    func dismissAllBackgroundNotifications() {
        pendingNotifications.removeAll()
    }

    // MARK: - MCP Config

    /// Writes a per-launch .mcp.json that points the spawned claude at Odin's
    /// in-process MCP server. Returns the temp file path, or nil on failure.
    /// The X-Session-Id header lets the server identify which Odin tab made a
    /// given tool call so background-task completions can be routed back.
    private static func writeMCPConfig(url: String, sessionId: String) -> String? {
        let dict: [String: Any] = [
            "mcpServers": [
                "odin": [
                    "type": "http",
                    "url": url,
                    "headers": [
                        "X-Session-Id": sessionId
                    ]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted]
        ) else { return nil }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let path = NSTemporaryDirectory() + "odin-mcp-\(suffix).json"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    private static func buildEnvironment(sessionId: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["ODIN_SESSION_ID"] = sessionId
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

// MARK: - Process Delegate Bridge

/// Bridges LocalProcessDelegate callbacks to closures.
/// All callbacks execute on the main dispatch queue (set via LocalProcess init).
@MainActor
private final class ProcessBridge: LocalProcessDelegate, @unchecked Sendable {
    let onData: (ArraySlice<UInt8>) -> Void
    let onTerminated: (Int32?) -> Void
    let onGetWindowSize: () -> winsize

    init(onData: @escaping (ArraySlice<UInt8>) -> Void,
         onTerminated: @escaping (Int32?) -> Void,
         onGetWindowSize: @escaping () -> winsize) {
        self.onData = onData
        self.onTerminated = onTerminated
        self.onGetWindowSize = onGetWindowSize
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            self.onTerminated(exitCode)
        }
    }

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            self.onData(slice)
        }
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated {
            self.onGetWindowSize()
        }
    }
}
#endif
