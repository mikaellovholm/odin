#if os(macOS)
import Foundation

@MainActor
final class BackgroundTaskRegistry {
    static let shared = BackgroundTaskRegistry()

    /// Soft cap on retained runners. Running tasks are never evicted; the
    /// oldest completed/failed tasks fall off when the registry grows past
    /// this size. 50 is generous for human-driven use — the goal is just to
    /// stop unbounded memory growth from a long-lived session.
    private let maxRetained = 50

    private var tasks: [String: BackgroundClaudeRunner] = [:]

    private init() {}

    func create(
        prompt: String,
        cwd: String,
        parentSessionId: String? = nil
    ) throws -> BackgroundClaudeRunner {
        guard let claudePath = ClaudePath.resolve() else {
            throw OdinMCPError.claudeNotFound
        }
        let id = "t-" + UUID().uuidString.prefix(8).lowercased()
        let runner = BackgroundClaudeRunner(
            id: id,
            prompt: prompt,
            cwd: cwd,
            parentSessionId: parentSessionId
        )
        tasks[id] = runner
        try runner.start(claudePath: claudePath)
        pruneIfNeeded()
        return runner
    }

    func get(_ id: String) -> BackgroundClaudeRunner? {
        tasks[id]
    }

    func all() -> [BackgroundClaudeRunner] {
        Array(tasks.values)
    }

    private func pruneIfNeeded() {
        guard tasks.count > maxRetained else { return }
        let completed = tasks.values
            .filter { $0.state != .running }
            .sorted { $0.createdAt < $1.createdAt }
        let overflow = tasks.count - maxRetained
        for runner in completed.prefix(overflow) {
            tasks.removeValue(forKey: runner.id)
        }
    }
}
#endif
