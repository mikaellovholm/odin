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
    /// Bottom shell pane (⇧⌘T). Survives detail-view rebuilds so the zsh
    /// process keeps running across session switches.
    let shellViewModel: ShellTerminalViewModel
    /// Owns the review side-panel state (selected run, pinned-vs-latest).
    /// Findings themselves live on `ReviewRun` in `ReviewRunRegistry`, so this
    /// VM is intentionally thin — it survives detail-view rebuilds just to
    /// keep `pinnedRunId` stable across tab switches.
    let reviewViewModel: ReviewViewModel
    /// Project file-tree side panel (⇧⌘P). Per-session so the expanded set,
    /// loaded tree, and currently-open file survive detail-view rebuilds.
    let projectViewModel: ProjectPanelViewModel
    /// Per-session visibility of the project panel. Toggled by ⇧⌘P on the
    /// active session; not persisted across app launches.
    var projectPanelVisible: Bool = false
    /// Per-session right-pane mode (diff / review / hidden). Toggled by ⇧⌘D
    /// and ⇧⌘R on the active session; not persisted across app launches so
    /// new sessions always start hidden and one tab's pane choice doesn't
    /// follow you into another.
    var rightPaneMode: RightPaneMode = .hidden
    /// Per-session visibility of the bottom shell pane (⇧⌘T). Matches the
    /// per-session pattern of `projectPanelVisible` / `rightPaneMode` so
    /// toggling on one session doesn't flip the others.
    var shellPaneVisible: Bool = false

    init(workingDirectory: String, id: UUID = UUID()) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.displayName = (workingDirectory as NSString).lastPathComponent
        let vm = LocalTerminalViewModel()
        vm.workingDirectory = workingDirectory
        self.viewModel = vm
        self.diffViewModel = DiffViewModel(workingDirectory: workingDirectory)
        let shell = ShellTerminalViewModel()
        shell.workingDirectory = workingDirectory
        self.shellViewModel = shell
        self.reviewViewModel = ReviewViewModel()
        self.projectViewModel = ProjectPanelViewModel(workingDirectory: workingDirectory)
    }
}
#endif
