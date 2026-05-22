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
    /// Claude raised a generic `Notification` (slash-menu, idle reminder, MCP
    /// elicitation) or the PTY-silence heartbeat promoted a stuck session.
    /// Drives the green "needs attention" dot.
    var awaitingInput: Bool = false
    /// Claude raised a permission/approval prompt (`PermissionRequest` hook
    /// or `Notification` matcher=permission_prompt). More urgent than
    /// `awaitingInput`; drives the cyan dot. Outranks every other status.
    var awaitingPermission: Bool = false
    /// Claude is compacting context (`PreCompact` fired, `PostCompact` has
    /// not). Drives the orange pulsing dot.
    var isCompacting: Bool = false
    /// Number of subagents this session has currently spawned via Claude
    /// Code's Task tool (tracked by `SubagentStart`/`SubagentStop` hooks).
    var activeSubagents: Int = 0
    var pendingNotifications: [BackgroundNotification] = []

    private(set) var sessionId: String?
    /// Path of the per-launch .mcp.json written by `writeMCPConfig`. Deleted
    /// when the session terminates or restarts to prevent $TMPDIR accumulation.
    private var mcpConfigPath: String?

    /// Path of the per-session state file written by the `odin-status.sh` hook
    /// and watched by `statusFileSource`. Cleaned up on teardown.
    private var statusFilePath: String?
    private var statusFileSource: DispatchSourceFileSystemObject?
    /// Count of consecutive watcher re-attaches inside `statusReattachWindow`.
    /// Resets to 0 on any successful read. Caps runaway re-open loops if the
    /// hook ever switches to a write pattern we genuinely can't recover from.
    private var statusReattachAttempts = 0
    /// Maximum consecutive re-attaches before we give up and leave the
    /// sidebar status frozen. Six attempts ≈ three lifecycle bursts of two
    /// renames each; well above any normal hook write.
    private static let statusMaxReattachAttempts = 6

    /// Directory containing one marker file per running subagent. The hook
    /// adds/removes files on `SubagentStart`/`SubagentStop`; the view model
    /// recounts on every status-file watcher tick.
    private var subagentDirPath: String?

    /// Timestamp of the last byte received from the child PTY. Used by the
    /// idle-heartbeat timer to detect Claude blocking on a slash-command menu
    /// or other interactive prompt that doesn't fire the `Notification` hook.
    private var lastDataReceivedAt: Date?
    private var heartbeatTimer: DispatchSourceTimer?

    /// How long PTY output must be silent while `isActive` is true before we
    /// promote the session to `awaitingInput`. Bumped to 6s once PreToolUse /
    /// PostToolUse hooks were wired to refresh `lastDataReceivedAt` — they
    /// keep the heartbeat alive across long tool calls (Bash, MCP, etc.), so
    /// we only fall back to PTY-silence detection for the genuine "Claude
    /// printed a menu and is sitting on it" case, which doesn't need a 2s
    /// reflex.
    private static let heartbeatIdleThreshold: TimeInterval = 6.0

    private var process: LocalProcess?
    private var bridge: LocalProcessClosureDelegate?
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
           let authToken = OdinMCPServer.shared.authToken,
           let configPath = Self.writeMCPConfig(url: mcpURL, sessionId: sessionId, authToken: authToken) {
            args.append(contentsOf: ["--mcp-config", configPath])
            mcpConfigPath = configPath
        }

        let bridge = LocalProcessClosureDelegate(
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
        // Spawn claude directly with an explicit PATH instead of going through
        // `zsh -ilc`. Sourcing ~/.zprofile / ~/.zshrc trusts files an attacker
        // (or a buggy script) could have rewritten, and `which claude` from
        // such a shell would happily return a poisoned binary. The PATH below
        // covers the standard claude install locations plus the usual system
        // dirs claude shells out to for git/npm/etc.
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
    /// `awaitingInput` and `awaitingPermission` are deliberately *not*
    /// cleared here: those flags mean "Claude is blocked on user input /
    /// approval", which is only resolved by the user actually responding
    /// (UserPromptSubmit / PreToolUse hook → state="working" → flags clear
    /// via `applyHookState`). Clicking the row to look at the prompt is not
    /// the same as responding to it.
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
        awaitingPermission = false
        isCompacting = false
        activeSubagents = 0
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
            let subagentDir = NSHomeDirectory() + "/.claude/odin-status/\(oldId).subagents"
            try? FileManager.default.removeItem(atPath: subagentDir)
        }
        sessionId = nil
        subagentDirPath = nil
        if let path = mcpConfigPath {
            try? FileManager.default.removeItem(atPath: path)
            mcpConfigPath = nil
        }
    }

    // MARK: - Hook-driven status

    /// Pre-creates the per-session state file and starts a `DispatchSource`
    /// watcher on it. The `odin-status.sh` hook (registered by
    /// `OdinHookInstaller`) writes one of `working`, `idle`, `awaiting-input`,
    /// `awaiting-permission`, or `compacting` into this file on each Claude
    /// lifecycle event; we drive `isActive`, `awaitingInput`,
    /// `awaitingPermission`, `isCompacting`, and `didFinish` from those
    /// writes. Subagent start/stop hooks `touch` the file (no content
    /// change) so the same watcher triggers `refreshSubagentCount`.
    private func startStatusWatcher(sessionId: String) {
        let dir = NSHomeDirectory() + "/.claude/odin-status"
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let path = dir + "/\(sessionId).state"
        subagentDirPath = dir + "/\(sessionId).subagents"
        statusFilePath = path
        statusReattachAttempts = 0
        attachStatusWatcher(path: path)
    }

    /// Opens the state file, creates a kqueue source for it, and arms the
    /// reattach handler. Extracted from `startStatusWatcher` so we can call
    /// it again from `reattachStatusWatcherIfNeeded` when the file is
    /// replaced via atomic rename (the hook currently uses
    /// truncate-and-overwrite, but a future change could switch — better to
    /// defend now than fail silently then).
    private func attachStatusWatcher(path: String) {
        // Pre-create with empty content so we have a stable inode to watch.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[Odin] failed to open status file for watching: \(path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // .attrib catches the `touch` nudges that subagent-start/-stop
            // emit (they don't change the file content, only mtime).
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        // Capture `src` so the handler can read the actual event mask via
        // `data` and react to .delete/.rename specifically — we need to know
        // *why* we were notified before deciding whether to re-open the file.
        src.setEventHandler { [weak self, weak src] in
            guard let self else { return }
            let mask = src?.data ?? []
            if mask.contains(.delete) || mask.contains(.rename) {
                self.reattachStatusWatcherIfNeeded()
            } else {
                self.statusReattachAttempts = 0
                self.readStatusFile()
            }
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

    /// Called when the watcher fires `.delete` or `.rename` — the original
    /// inode is gone, so the existing FD will never see another event. Cancel
    /// the dead source and re-open against the path on the next runloop tick
    /// (the hook script that triggered the rename may still be finishing its
    /// write). Bails after a small number of consecutive attempts to avoid a
    /// runaway loop if the hook ever genuinely deletes the file on every event.
    private func reattachStatusWatcherIfNeeded() {
        statusReattachAttempts += 1
        guard statusReattachAttempts <= Self.statusMaxReattachAttempts else {
            NSLog("[Odin] status watcher re-attach limit hit; status updates paused for this session")
            statusFileSource?.cancel()
            statusFileSource = nil
            return
        }
        statusFileSource?.cancel()
        statusFileSource = nil
        guard let path = statusFilePath else { return }
        DispatchQueue.main.async { [weak self] in
            self?.attachStatusWatcher(path: path)
        }
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
        // Skip while compacting: PreCompact deliberately starves the PTY for
        // a while, and the orange "compacting" dot already explains the
        // silence — falsely promoting to green here would override it (per
        // the status-priority order in ClaudeSessionRow, `awaitingInput`
        // beats `isCompacting`).
        guard isActive, !awaitingInput, !isCompacting,
              let last = lastDataReceivedAt,
              Date().timeIntervalSince(last) >= Self.heartbeatIdleThreshold
        else { return }
        awaitingInput = true
    }

    private func readStatusFile() {
        // Subagent count is independent of the state-name pipeline — refresh
        // it on every watcher tick (the hook touches the state file after
        // mutating the subagent dir to guarantee a tick fires).
        refreshSubagentCount()
        guard let path = statusFilePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8) else { return }
        let state = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isEmpty else { return }
        applyHookState(state)
    }

    private func refreshSubagentCount() {
        guard let dir = subagentDirPath else { return }
        let count = (try? FileManager.default.contentsOfDirectory(atPath: dir).count) ?? 0
        if activeSubagents != count {
            activeSubagents = count
        }
    }

    private func applyHookState(_ hookState: String) {
        let wasActive = isActive
        switch hookState {
        case "working":
            isActive = true
            awaitingInput = false
            awaitingPermission = false
            isCompacting = false
            // PreToolUse / PostToolUse fire `working` around every tool call.
            // Treat each write as a liveness signal so the heartbeat doesn't
            // promote a long Bash / MCP call to awaitingInput.
            lastDataReceivedAt = Date()
        case "idle":
            isActive = false
            awaitingInput = false
            awaitingPermission = false
            isCompacting = false
            if wasActive { didFinish = true }
        case "awaiting-input":
            // Claude is still mid-turn, just blocked on user input — keep
            // `isActive` true so that when the user responds and bytes resume
            // flowing, `noteDataReceived` can clear `awaitingInput` (it gates
            // the demotion on `isActive` so unrelated stray bytes don't trip it).
            awaitingInput = true
        case "awaiting-permission":
            // PermissionRequest hook — more specific than awaiting-input.
            // Both flags may be set if Notification also fires; UI prioritises
            // permission, and they all clear together on the next "working".
            awaitingPermission = true
        case "compacting":
            // PreCompact: Claude isn't idle but isn't producing output
            // either. `checkHeartbeat` skips while `isCompacting` is true,
            // so we don't falsely promote to `awaitingInput` during the
            // PTY-silence stretch. Still refresh `lastDataReceivedAt` so
            // that PostCompact → "working" doesn't immediately trip the
            // 6s threshold on its first heartbeat tick.
            isCompacting = true
            lastDataReceivedAt = Date()
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

    // MARK: - MCP Config

    /// Writes a per-launch .mcp.json that points the spawned claude at Odin's
    /// in-process MCP server. Returns the temp file path, or nil on failure.
    /// The X-Session-Id header lets the server identify which Odin tab made a
    /// given tool call so background-task completions can be routed back.
    /// X-Odin-Auth carries the per-launch shared secret — without it the
    /// server returns 401, so external loopback clients can't drive the MCP.
    private static func writeMCPConfig(url: String, sessionId: String, authToken: String) -> String? {
        let dict: [String: Any] = [
            "mcpServers": [
                "odin": [
                    "type": "http",
                    "url": url,
                    "headers": [
                        "X-Session-Id": sessionId,
                        "X-Odin-Auth": authToken
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
        // Explicit PATH — see startClaude for why we don't trust rc-sourced
        // values. Standard claude install locations come first; system dirs
        // last so claude can still find git, node, etc.
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin"
        return env.map { "\($0.key)=\($0.value)" }
    }
}

#endif
