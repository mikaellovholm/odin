#if os(macOS)
import Foundation

@MainActor
@Observable
final class ClaudeSession: Identifiable {
    let id: UUID
    let workingDirectory: String
    let displayName: String
    let viewModel: LocalTerminalViewModel
    /// Owns the diff side-panel state so it survives detail-view rebuilds
    /// (same pattern as `viewModel`). Holds the FSEvents watcher + file list +
    /// currently-loaded diff for this session's worktree.
    let diffViewModel: DiffViewModel

    init(workingDirectory: String, id: UUID = UUID()) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.displayName = (workingDirectory as NSString).lastPathComponent
        let vm = LocalTerminalViewModel()
        vm.workingDirectory = workingDirectory
        self.viewModel = vm
        self.diffViewModel = DiffViewModel(workingDirectory: workingDirectory)
    }
}
#endif
