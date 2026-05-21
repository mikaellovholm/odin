#if os(macOS)
import Foundation

enum OdinMCPError: Error, CustomStringConvertible {
    case claudeNotFound
    case taskNotFound(String)
    case invalidArgument(String)
    case spawnFailed(String)

    var description: String {
        switch self {
        case .claudeNotFound:
            return "claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
        case .taskNotFound(let id):
            return "task not found: \(id)"
        case .invalidArgument(let msg):
            return "invalid argument: \(msg)"
        case .spawnFailed(let msg):
            return "failed to spawn claude: \(msg)"
        }
    }
}

@MainActor
@Observable
final class BackgroundClaudeRunner {
    enum State: Equatable {
        case running
        case completed(String)
        case failed(String)
    }

    let id: String
    let prompt: String
    let cwd: String
    let parentSessionId: String?
    let model: String?
    /// When set, the worker gets a `--mcp-config` pointing at OdinMCP with
    /// review-routing headers, and the runner auto-resolves the corresponding
    /// concern / fix worker in `ReviewRunRegistry` on exit.
    let reviewContext: ReviewWorkerContext?
    let createdAt: Date

    /// Notified after the runner transitions out of `.running`. The registry
    /// uses this to keep `runningCount` accurate without polling.
    var onFinish: ((State) -> Void)?

    private(set) var state: State = .running
    /// Set the moment `cancel()` is called. `finish` reads this so the final
    /// state reads as "cancelled by user" instead of a bare exit-code message.
    private(set) var wasCancelled: Bool = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdoutBuffer = Data()
    @ObservationIgnored private var stderrBuffer = Data()
    /// Per-worker `.mcp.json` in $TMPDIR. Written in `start` when `reviewContext`
    /// is set, deleted in `finish`.
    @ObservationIgnored private var mcpConfigPath: String?

    init(
        id: String,
        prompt: String,
        cwd: String,
        parentSessionId: String? = nil,
        model: String? = nil,
        reviewContext: ReviewWorkerContext? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.cwd = cwd
        self.parentSessionId = parentSessionId
        self.model = model
        self.reviewContext = reviewContext
        self.createdAt = Date()
    }

    func start(claudePath: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        var args = [
            "-p", prompt,
            "--dangerously-skip-permissions",
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        // Review workers reach back into Odin via a per-worker .mcp.json. Plain
        // background tasks (no reviewContext) skip this — they don't need to
        // call submit_finding/submit_fix_result and we avoid expanding the
        // attack surface for prompts that have no business calling back.
        if let configPath = Self.writeMCPConfigIfNeeded(
            parentSessionId: parentSessionId,
            taskId: id,
            reviewContext: reviewContext
        ) {
            args.append(contentsOf: ["--mcp-config", configPath])
            mcpConfigPath = configPath
        }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env.removeValue(forKey: "CLAUDE_CODE_PROJECT_DIR")
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        // Collect all output in the termination handler rather than using
        // readabilityHandler callbacks. Mixing the two creates an ordering race:
        // readabilityHandler Tasks dispatched to MainActor can execute *after*
        // the terminationHandler Task (and therefore after finish()), leaving
        // stdoutBuffer/stderrBuffer incomplete when the result is captured.
        //
        // Since the process has already exited when terminationHandler fires,
        // both write-ends are closed and readDataToEndOfFile() returns
        // immediately with all buffered output — no blocking occurs.
        //
        // Note: macOS pipe buffers are ~64 KB. Workers producing more output
        // than that may stall; keep spawned prompts concise.
        p.terminationHandler = { [weak self] proc in
            let output = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errput = errPipe.fileHandleForReading.readDataToEndOfFile()
            let exitCode = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stdoutBuffer = output
                self.stderrBuffer = errput
                self.finish(exitCode: exitCode)
            }
        }

        do {
            try p.run()
        } catch {
            throw OdinMCPError.spawnFailed("\(error)")
        }
        process = p
    }

    private func finish(exitCode: Int32) {
        guard state == .running else { return }
        let stdoutText = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrBuffer, encoding: .utf8) ?? ""
        // Release raw byte buffers and the Process reference now that we've
        // extracted everything we need. Whatever the consumer wants lives in
        // `state` from here on. Pipe FDs were already closed by
        // readDataToEndOfFile in the termination handler.
        stdoutBuffer = Data()
        stderrBuffer = Data()
        process = nil
        if let path = mcpConfigPath {
            try? FileManager.default.removeItem(atPath: path)
            mcpConfigPath = nil
        }
        let trimmed = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode == 0 {
            state = .completed(trimmed)
        } else if wasCancelled {
            state = .failed("cancelled by user")
        } else {
            let stderrTail = String(stderrText.suffix(2000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = stderrTail.isEmpty
                ? "claude exited with code \(exitCode)"
                : "claude exited with code \(exitCode). stderr: \(stderrTail)"
            state = .failed(msg)
        }
        autoResolveReviewContext(exitCode: exitCode, stderrTail: stderrText)
        appendPendingNotification()
        pushBannerToParent()
        onFinish?(state)
    }

    /// If this runner was spawned as a Phase-1 reviewer or Phase-2 fixer,
    /// poke `ReviewRunRegistry` so the panel stops showing the worker as
    /// in-flight. The registry's auto-resolve methods are idempotent and never
    /// downgrade a self-reported terminal state — see their docs.
    private func autoResolveReviewContext(exitCode: Int32, stderrTail: String) {
        guard let ctx = reviewContext else { return }
        let success = exitCode == 0
        let message: String? = success
            ? nil
            : wasCancelled
                ? "cancelled by user"
                : {
                    let tail = String(stderrTail.suffix(500))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return tail.isEmpty
                        ? "worker exited with code \(exitCode)"
                        : "worker exited with code \(exitCode): \(tail)"
                }()
        switch ctx.role {
        case .reviewer(let concern):
            ReviewRunRegistry.shared.autoResolveReviewerOnExit(
                reviewId: ctx.reviewId,
                concern: concern,
                taskId: id,
                success: success,
                message: message
            )
        case .fixer:
            ReviewRunRegistry.shared.autoResolveFixerOnExit(
                reviewId: ctx.reviewId,
                taskId: id,
                success: success,
                message: message
            )
        }
    }

    /// Writes a per-worker `.mcp.json` to $TMPDIR with the headers OdinMCP
    /// reads to route review tool calls. Returns nil for non-review workers,
    /// when the parent session id is missing (we can't route without it), or
    /// when the OdinMCP server isn't listening yet — in any of those cases
    /// the worker just runs without MCP access.
    private static func writeMCPConfigIfNeeded(
        parentSessionId: String?,
        taskId: String,
        reviewContext: ReviewWorkerContext?
    ) -> String? {
        guard let context = reviewContext else { return nil }
        guard let parentSessionId, !parentSessionId.isEmpty else { return nil }
        guard let url = OdinMCPServer.shared.mcpURL else { return nil }
        var headers: [String: String] = [
            "X-Session-Id": parentSessionId,
            "X-Task-Id": taskId,
            "X-Review-Id": context.reviewId
        ]
        switch context.role {
        case .reviewer(let concern):
            headers["X-Concern"] = concern
        case .fixer(let file):
            headers["X-Fix-File"] = file
        }
        let dict: [String: Any] = [
            "mcpServers": [
                "odin": [
                    "type": "http",
                    "url": url,
                    "headers": headers
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted]
        ) else { return nil }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let path = NSTemporaryDirectory() + "odin-mcp-worker-\(suffix).json"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    /// Push a UI banner into the parent Odin Claude tab so the user sees the
    /// completion without prompting Claude first. Distinct from the pending
    /// file: the banner is for the human, the file is for Claude's context.
    private func pushBannerToParent() {
        guard let sessionId = parentSessionId, !sessionId.isEmpty else { return }
        guard let viewModel = OdinSessionRegistry.shared.viewModel(for: sessionId) else { return }
        let preview: String
        let kind: BackgroundNotification.Kind
        switch state {
        case .running:
            return
        case .completed(let result):
            preview = String(result.prefix(200))
                .replacingOccurrences(of: "\n", with: " ")
            kind = .success
        case .failed(let error):
            preview = String(error.prefix(200))
                .replacingOccurrences(of: "\n", with: " ")
            kind = .failure
        }
        viewModel.addBackgroundNotification(
            BackgroundNotification(taskId: id, kind: kind, preview: preview)
        )
    }

    /// If the task was spawned by an identifiable Odin Claude tab, append a
    /// notification to that tab's pending file so the UserPromptSubmit hook
    /// can surface the result on the next user turn.
    private func appendPendingNotification() {
        guard let sessionId = parentSessionId, !sessionId.isEmpty else { return }
        let dir = NSHomeDirectory() + "/.claude/odin-pending"
        let file = dir + "/\(sessionId).txt"
        let snippet = String(prompt.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        let body: String
        switch state {
        case .running:
            return
        case .completed(let result):
            body = """
            <odin-background-notification>
            Task \(id) (prompt: "\(snippet)") completed.

            Result:
            \(result)
            </odin-background-notification>

            """
        case .failed(let error):
            body = """
            <odin-background-notification>
            Task \(id) (prompt: "\(snippet)") FAILED.

            Error:
            \(error)
            </odin-background-notification>

            """
        }
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
            if let data = body.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: file) {
                    // Append, but propagate FileHandle errors instead of
                    // silently overwriting an existing pending file — that
                    // would drop a previously-completed worker's result.
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    // .atomic (temp-file + rename) prevents a partial write
                    // if the app is killed while creating the pending file.
                    try data.write(to: URL(fileURLWithPath: file), options: .atomic)
                }
            }
        } catch {
            NSLog("[OdinMCP] failed to write pending notification: \(error)")
        }
    }

    /// Poll until completion or timeout. Returns nil on timeout or Task cancellation, state otherwise.
    func awaitCompletion(timeout: TimeInterval?) async -> State? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while state == .running {
            // Exit cleanly if the parent MCP connection was dropped and the
            // enclosing Task was cancelled (avoids holding the connection open
            // until the worker finishes or the timeout fires).
            if Task.isCancelled { return nil }
            if let deadline, Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return state
    }

    /// Send SIGTERM to the worker process. Idempotent — calling on a
    /// terminal-state runner is a no-op. The actual transition to `.failed`
    /// happens asynchronously via the existing terminationHandler; callers
    /// who need the final state should `awaitCompletion` or poll.
    /// Returns true if a process was actually signalled.
    @discardableResult
    func cancel() -> Bool {
        guard state == .running, let p = process, p.isRunning else { return false }
        wasCancelled = true
        p.terminate()
        return true
    }
}
#endif
