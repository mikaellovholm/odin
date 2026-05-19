#if os(macOS)
import SwiftUI

struct ClaudeSessionDetailView: View {
    let session: ClaudeSession
    @State private var keyboardDismissed = false
    @AppStorage(TerminalFontSettings.key) private var fontSize: Double = Double(TerminalFontSettings.defaultSize)
    @AppStorage("claude.shellPaneVisible") private var shellPaneVisible: Bool = false
    /// Three-state right pane: hidden / diff / review. Mutually exclusive by
    /// design — diff and review can't show at the same time (the user picked
    /// "separate toggleable pane" in the planning Q&A). New default is `.diff`
    /// to match the previous `diffPaneVisible: true` default; users who toggled
    /// the old key lose that preference but land on the same state.
    @AppStorage(RightPaneMode.storageKey) private var rightPaneMode: RightPaneMode = .diff

    private var viewModel: LocalTerminalViewModel { session.viewModel }

    var body: some View {
        Group {
            if shellPaneVisible {
                VSplitView {
                    topArea
                        .frame(minHeight: 200, maxHeight: .infinity)
                    shellPane
                        .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)
                }
            } else {
                topArea
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    shellPaneVisible.toggle()
                } label: {
                    Image(systemName: shellPaneVisible ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomthird.inset")
                }
                .help(shellPaneVisible ? "Hide terminal panel" : "Show terminal panel")
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    rightPaneMode = (rightPaneMode == .diff) ? .hidden : .diff
                } label: {
                    Image(systemName: rightPaneMode == .diff ? "sidebar.right" : "sidebar.squares.right")
                }
                .help(rightPaneMode == .diff ? "Hide diff pane" : "Show diff pane")
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    rightPaneMode = (rightPaneMode == .review) ? .hidden : .review
                } label: {
                    Image(systemName: rightPaneMode == .review ? "checklist.checked" : "checklist")
                }
                .help(rightPaneMode == .review ? "Hide review pane" : "Show review pane")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    @ViewBuilder
    private var topArea: some View {
        switch rightPaneMode {
        case .hidden:
            terminalArea
        case .diff:
            HSplitView {
                terminalArea
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                DiffPaneView(viewModel: session.diffViewModel)
                    .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
            }
        case .review:
            HSplitView {
                terminalArea
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                ReviewPaneView(
                    viewModel: session.reviewViewModel,
                    parentSessionId: viewModel.sessionId,
                    workingDirectory: session.workingDirectory
                )
                .frame(minWidth: 320, idealWidth: 400, maxHeight: .infinity)
            }
        }
    }

    private var shellPane: some View {
        ZStack {
            TerminalRepresentable(
                onTerminalViewCreated: { session.shellViewModel.setTerminalView($0) },
                onDataSend: { session.shellViewModel.sendData($0) },
                onSizeChanged: { session.shellViewModel.resizeTerminal(cols: $0, rows: $1) },
                fontSize: CGFloat(fontSize),
                isConnected: session.shellViewModel.state == .running,
                keyboardDismissed: $keyboardDismissed
            )
            .opacity(session.shellViewModel.state == .running ? 1 : 0)

            if case .exited(let code) = session.shellViewModel.state {
                VStack(spacing: 8) {
                    Text(code.map { "Shell exited (\($0))" } ?? "Shell exited")
                        .foregroundStyle(.secondary)
                    Button("Restart") { session.shellViewModel.restart() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(.black)
        .onAppear { session.shellViewModel.startIfNeeded() }
    }

    private var terminalArea: some View {
        ZStack {
            TerminalRepresentable(
                onTerminalViewCreated: { viewModel.setTerminalView($0) },
                onDataSend: { viewModel.sendData($0) },
                onSizeChanged: { viewModel.resizeTerminal(cols: $0, rows: $1) },
                fontSize: CGFloat(fontSize),
                isConnected: viewModel.state == .running,
                keyboardDismissed: $keyboardDismissed
            )
            .opacity(viewModel.state == .running ? 1 : 0)

            if viewModel.state != .running {
                stateOverlay
            }
        }
        .background(.black)
        .background(FontZoomShortcuts())
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
