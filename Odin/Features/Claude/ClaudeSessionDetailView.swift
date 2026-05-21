#if os(macOS)
import SwiftUI

struct ClaudeSessionDetailView: View {
    let session: ClaudeSession
    @State private var keyboardDismissed = false
    @AppStorage(TerminalFontSettings.key) private var fontSize: Double = Double(TerminalFontSettings.defaultSize)

    private var viewModel: LocalTerminalViewModel { session.viewModel }

    var body: some View {
        composedBody
            .background(paneShortcuts)
            .onChange(of: session.shellPaneVisible) { _, newValue in
                if newValue { focusShell() }
            }
    }

    /// Hidden buttons that register ⇧⌘P / ⇧⌘T / ⇧⌘D / ⇧⌘R as pane toggles.
    /// Replaces the toolbar buttons so the window matches the Notes / Sessions
    /// chromeless look; the sidebar's shortcut-hints footer documents them.
    private var paneShortcuts: some View {
        ZStack {
            Button("") { session.projectPanelVisible.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { session.shellPaneVisible.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") {
                session.rightPaneMode = (session.rightPaneMode == .diff) ? .hidden : .diff
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") {
                session.rightPaneMode = (session.rightPaneMode == .review) ? .hidden : .review
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    /// HSplitView columns from left to right (each conditional):
    /// [project panel] [file viewer] [terminal/shell] [diff or review].
    /// When neither the project panel nor a right-pane is visible we bypass
    /// the HSplitView entirely so the terminal fills the area without a
    /// stray drag handle (matches the original `.hidden` case).
    @ViewBuilder
    private var composedBody: some View {
        let projectVisible = session.projectPanelVisible
        let fileVisible = projectVisible && session.projectViewModel.selectedFileURL != nil
        let rightVisible = session.rightPaneMode != .hidden

        if !projectVisible && !rightVisible {
            leftColumn
        } else {
            HSplitView {
                if projectVisible {
                    ProjectPanelView(viewModel: session.projectViewModel)
                        .frame(minWidth: 200, idealWidth: 220, maxWidth: 420, maxHeight: .infinity)
                }
                if fileVisible {
                    FileViewerView(
                        workingDirectory: session.workingDirectory,
                        viewModel: session.projectViewModel
                    )
                    .frame(minWidth: 280, idealWidth: 600, maxHeight: .infinity)
                    .layoutPriority(1)
                }
                leftColumn
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if session.rightPaneMode == .diff {
                    DiffPaneView(viewModel: session.diffViewModel)
                        .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
                } else if session.rightPaneMode == .review {
                    ReviewPaneView(
                        viewModel: session.reviewViewModel,
                        parentSessionId: viewModel.sessionId,
                        workingDirectory: session.workingDirectory,
                        onOpenFile: { relPath, line in
                            // Reviewer findings carry repo-relative paths; the
                            // project panel works in absolute URLs. Resolve
                            // against the session's worktree root, then make
                            // sure the panel is visible before handing the
                            // deep-link to the view model.
                            let url = URL(fileURLWithPath: session.workingDirectory)
                                .appendingPathComponent(relPath)
                            if !session.projectPanelVisible {
                                session.projectPanelVisible = true
                            }
                            session.projectViewModel.openFile(at: url, line: line)
                        }
                    )
                    .frame(minWidth: 320, idealWidth: 400, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var leftColumn: some View {
        if session.shellPaneVisible {
            VSplitView {
                terminalArea
                    .frame(minHeight: 200, maxHeight: .infinity)
                shellPane
                    .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)
            }
        } else {
            terminalArea
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
                keyboardDismissed: $keyboardDismissed,
                useHomebrewTheme: true,
                backgroundColorOverride: TerminalTheme.shellBackground
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
        // Matches the SwiftTerm canvas inside so any startup gap / exited
        // overlay reads as the same surface, not pure black against the
        // Claude session's pure-black canvas above.
        .background(Color(nsColor: TerminalTheme.shellBackground))
        .onAppear {
            session.shellViewModel.startIfNeeded()
            focusShell()
        }
        .onChange(of: session.shellViewModel.state) { _, newState in
            if newState == .running { focusShell() }
        }
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

    private func focusShell() {
        DispatchQueue.main.async {
            guard let tv = session.shellViewModel.terminalView else { return }
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
