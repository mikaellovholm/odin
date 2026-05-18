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

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.stdoutBuffer.append(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.stderrBuffer.append(chunk)
            }
        }

        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            let exitCode = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stdoutBuffer.append(remainingOut)
                self.stderrBuffer.append(remainingErr)
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
                    try data.write(to: URL(fileURLWithPath: file))
                }
            }
        } catch {
            NSLog("[OdinMCP] failed to write pending notification: \(error)")
        }
    }

    /// Poll until completion or timeout. Returns nil on timeout, state otherwise.
    func awaitCompletion(timeout: TimeInterval?) async -> State? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while state == .running {
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
