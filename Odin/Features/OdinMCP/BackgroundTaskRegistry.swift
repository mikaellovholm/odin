#if os(macOS)
import Foundation

@MainActor
@Observable
final class BackgroundTaskRegistry {
    static let shared = BackgroundTaskRegistry()

    /// Soft cap on retained runners. Running tasks are never evicted; the
    /// oldest completed/failed tasks fall off when the registry grows past
    /// this size. 50 is generous for human-driven use — the goal is just to
    /// stop unbounded memory growth from a long-lived session.
    private let maxRetained = 50

    private(set) var tasks: [String: BackgroundClaudeRunner] = [:]

    /// Number of runners currently in the `.running` state. Maintained
    /// incrementally so SwiftUI views observing the registry update the
    /// moment a worker starts or finishes.
    private(set) var runningCount: Int = 0

    private init() {}

    func create(
        prompt: String,
        cwd: String,
        parentSessionId: String? = nil,
        model: String? = nil,
        reviewContext: ReviewWorkerContext? = nil
    ) throws -> BackgroundClaudeRunner {
        guard let claudePath = ClaudePath.resolve() else {
            throw OdinMCPError.claudeNotFound
        }
        let id = "t-" + UUID().uuidString.prefix(8).lowercased()
        let runner = BackgroundClaudeRunner(
            id: id,
            prompt: prompt,
            cwd: cwd,
            parentSessionId: parentSessionId,
            model: model,
            reviewContext: reviewContext
        )
        runner.onFinish = { [weak self] _ in
            guard let self else { return }
            self.runningCount = max(self.runningCount - 1, 0)
        }
        // Start *before* registering so a spawn failure doesn't leave a
        // zombie .running entry in the registry (with `runningCount` bumped
        // forever). The runner only becomes visible once we know its process
        // is alive.
        do {
            try runner.start(claudePath: claudePath)
        } catch {
            runner.onFinish = nil
            throw error
        }
        tasks[id] = runner
        runningCount += 1
        pruneIfNeeded()
        return runner
    }

    func get(_ id: String) -> BackgroundClaudeRunner? {
        tasks[id]
    }

    func all() -> [BackgroundClaudeRunner] {
        Array(tasks.values)
    }

    /// Count of in-flight runners spawned by the given Odin Claude session.
    /// Tasks whose parent launch has been restarted (different session id) no
    /// longer count toward that session.
    func runningCount(forSessionId sessionId: String) -> Int {
        tasks.values.reduce(0) { acc, runner in
            (runner.state == .running && runner.parentSessionId == sessionId) ? acc + 1 : acc
        }
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
