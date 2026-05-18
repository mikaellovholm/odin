#if os(macOS)
import Foundation

@MainActor
final class BackgroundTaskRegistry {
    static let shared = BackgroundTaskRegistry()

    private var tasks: [String: BackgroundClaudeRunner] = [:]

    private init() {}

    func create(prompt: String, cwd: String) throws -> BackgroundClaudeRunner {
        guard let claudePath = ClaudePath.resolve() else {
            throw OdinMCPError.claudeNotFound
        }
        let id = "t-" + UUID().uuidString.prefix(8).lowercased()
        let runner = BackgroundClaudeRunner(id: id, prompt: prompt, cwd: cwd)
        tasks[id] = runner
        try runner.start(claudePath: claudePath)
        return runner
    }

    func get(_ id: String) -> BackgroundClaudeRunner? {
        tasks[id]
    }

    func all() -> [BackgroundClaudeRunner] {
        Array(tasks.values)
    }
}
#endif
