#if os(macOS)
import Foundation

@MainActor
@Observable
final class ClaudeSessionStore {
    private(set) var sessions: [ClaudeSession] = []
    var selectedSessionID: UUID?
    private let defaultsKey = "claude.sessionDirectories"

    func loadPersisted() {
        guard sessions.isEmpty else { return }
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        sessions = paths.map { ClaudeSession(workingDirectory: $0) }
    }

    @discardableResult
    func addSession(directory: String) -> ClaudeSession {
        let session = ClaudeSession(workingDirectory: directory)
        sessions.append(session)
        persist()
        return session
    }

    func remove(_ session: ClaudeSession) {
        session.viewModel.terminate()
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first(where: { $0.id != session.id })?.id
        }
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    func select(_ session: ClaudeSession) {
        selectedSessionID = session.id
        if session.viewModel.state == .notStarted {
            session.viewModel.startClaude()
        }
        session.viewModel.clearFinished()
        // Dismiss only the notifications visible at click time. If a worker
        // completes between this turn and a future scheduler tick, its
        // notification gets its own row + checkmark — we don't accidentally
        // clear something the user never saw.
        let acknowledgedIds = session.viewModel.pendingNotifications.map(\.id)
        for id in acknowledgedIds {
            session.viewModel.dismissBackgroundNotification(id: id)
        }
    }

    private func persist() {
        let paths = sessions.map { $0.workingDirectory }
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }
}
#endif
