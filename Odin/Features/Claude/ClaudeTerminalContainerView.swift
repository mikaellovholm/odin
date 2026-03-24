#if os(macOS)
import SwiftUI

struct ClaudeTerminalContainerView: View {
    @Bindable var viewModel: LocalTerminalViewModel
    @State private var keyboardDismissed = false
    @State private var needsDirectorySelection = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalRepresentable(
                onTerminalViewCreated: { viewModel.setTerminalView($0) },
                onDataSend: { viewModel.sendData($0) },
                onSizeChanged: { viewModel.resizeTerminal(cols: $0, rows: $1) },
                onTitleChanged: { viewModel.handleTitleChanged($0) },
                isConnected: viewModel.state == .running,
                keyboardDismissed: $keyboardDismissed
            )
            .opacity(viewModel.state == .running ? 1 : 0)

            if needsDirectorySelection {
                directoryPicker
            } else if viewModel.state != .running {
                stateOverlay
            }

        }
        .background(.black)
        .ignoresSafeArea(.container)
    }

    private var directoryPicker: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Working Directory")
                .font(.title2.bold())

            Text(viewModel.workingDirectory)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Choose Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: viewModel.workingDirectory)
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.workingDirectory = url.path
                    }
                }
                .buttonStyle(.bordered)

                Button("Start Claude") {
                    needsDirectorySelection = false
                    viewModel.startClaude()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch viewModel.state {
        case .starting:
            ProgressView("Starting Claude...")

        case .running:
            EmptyView()

        case .exited(let code):
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Claude exited")
                    .font(.headline)
                if let code {
                    Text("Exit code: \(code)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Restart") {
                    needsDirectorySelection = true
                    viewModel.restart()
                }
                .buttonStyle(.borderedProminent)
            }

        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Error")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    needsDirectorySelection = true
                    viewModel.restart()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
#endif
