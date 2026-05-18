#if os(macOS)
import Foundation

@MainActor
@Observable
final class ClaudeSession: Identifiable {
    let id: UUID
    let workingDirectory: String
    let displayName: String
    let viewModel: LocalTerminalViewModel

    init(workingDirectory: String, id: UUID = UUID()) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.displayName = (workingDirectory as NSString).lastPathComponent
        let vm = LocalTerminalViewModel()
        vm.workingDirectory = workingDirectory
        self.viewModel = vm
    }
}
#endif
