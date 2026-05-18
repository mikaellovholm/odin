#if os(macOS)
import Foundation

/// Maps the per-launch sessionId minted in `LocalTerminalViewModel.startClaude`
/// to its owning view model, weakly. Lets `BackgroundClaudeRunner` find which
/// Odin Claude tab to surface a completion banner on, without forcing a
/// retain cycle if the user removes the session.
@MainActor
final class OdinSessionRegistry {
    static let shared = OdinSessionRegistry()

    private struct Entry {
        weak var viewModel: LocalTerminalViewModel?
    }

    private var entries: [String: Entry] = [:]

    private init() {}

    func register(_ viewModel: LocalTerminalViewModel, for sessionId: String) {
        entries[sessionId] = Entry(viewModel: viewModel)
    }

    func unregister(_ sessionId: String) {
        entries.removeValue(forKey: sessionId)
    }

    func viewModel(for sessionId: String) -> LocalTerminalViewModel? {
        entries[sessionId]?.viewModel
    }
}
#endif
