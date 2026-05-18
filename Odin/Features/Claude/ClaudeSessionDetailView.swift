#if os(macOS)
import SwiftUI

struct ClaudeSessionDetailView: View {
    let session: ClaudeSession
    @State private var keyboardDismissed = false

    private var viewModel: LocalTerminalViewModel { session.viewModel }

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
        .onAppear { focusTerminal() }
        .onChange(of: viewModel.state) { _, newState in
            if newState == .running { focusTerminal() }
        }
        .onChange(of: viewModel.didFinish) { _, didFinish in
            // Being-watched counts as acknowledgement: clear the "just
            // finished" yellow-stable flag immediately so switching to
            // another session afterwards doesn't surface it as unseen work.
            // (`awaitingInput` is deliberately not cleared here — the user
            // hasn't actually responded to Claude yet just by looking.)
            if didFinish { viewModel.acknowledge() }
        }
    }

    private func focusTerminal() {
        DispatchQueue.main.async {
            guard let tv = viewModel.terminalView else { return }
            tv.window?.makeFirstResponder(tv)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch viewModel.state {
        case .notStarted:
            ProgressView()

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
