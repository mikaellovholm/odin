#if os(macOS)
import SwiftUI

struct ClaudeTerminalContainerView: View {
    @State private var viewModel = LocalTerminalViewModel()
    @State private var keyboardDismissed = false

    var body: some View {
        ZStack {
            TerminalRepresentable(
                onTerminalViewCreated: { viewModel.setTerminalView($0) },
                onDataSend: { viewModel.sendData($0) },
                onSizeChanged: { viewModel.resizeTerminal(cols: $0, rows: $1) },
                isConnected: viewModel.state == .running,
                keyboardDismissed: $keyboardDismissed
            )
            .opacity(viewModel.state == .running ? 1 : 0)

            if viewModel.state != .running {
                stateOverlay
            }
        }
        .background(.black)
        .ignoresSafeArea(.container)
        .onAppear {
            if viewModel.state == .starting {
                viewModel.startClaude()
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
                    viewModel.restart()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
#endif
