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
    let createdAt: Date

    private(set) var state: State = .running
    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    init(id: String, prompt: String, cwd: String) {
        self.id = id
        self.prompt = prompt
        self.cwd = cwd
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
