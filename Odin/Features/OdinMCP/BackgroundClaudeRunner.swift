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
    let createdAt: Date

    private(set) var state: State = .running
    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    init(id: String, prompt: String, cwd: String, parentSessionId: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.cwd = cwd
        self.parentSessionId = parentSessionId
        self.createdAt = Date()
    }

    func start(claudePath: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = [
            "-p", prompt,
            "--dangerously-skip-permissions",
        ]
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
        let trimmed = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode == 0 {
            state = .completed(trimmed)
        } else {
            let stderrTail = String(stderrText.suffix(2000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = stderrTail.isEmpty
                ? "claude exited with code \(exitCode)"
                : "claude exited with code \(exitCode). stderr: \(stderrTail)"
            state = .failed(msg)
        }
        appendPendingNotification()
        pushBannerToParent()
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
                if FileManager.default.fileExists(atPath: file),
                   let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: file)) {
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

    func cancel() {
        process?.terminate()
    }
}
#endif
