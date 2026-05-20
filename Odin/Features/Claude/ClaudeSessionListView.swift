#if os(macOS)
import AppKit
import SwiftUI

struct ClaudeSessionListView: View {
    @Environment(ClaudeSessionStore.self) private var store

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 360)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(keyboardShortcuts)
        .onReceive(NotificationCenter.default.publisher(for: .odinCreateNewClaudeSession)) { _ in
            addSession()
        }
    }

    /// Hidden buttons that register ⌘1…⌘9 as shortcuts for the first nine sessions.
    private var keyboardShortcuts: some View {
        ZStack {
            ForEach(Array(store.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
                Button("") { store.select(session) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.sessions.isEmpty {
                emptySidebar
            } else {
                sessionList
            }
            Divider()
            shortcutHints
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var shortcutHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            shortcutRow(label: "New session", shortcut: "⌘N")
            shortcutRow(label: "Project pane", shortcut: "⇧⌘P")
            shortcutRow(label: "Diff pane", shortcut: "⇧⌘D")
            shortcutRow(label: "Review pane", shortcut: "⇧⌘R")
            shortcutRow(label: "Terminal pane", shortcut: "⇧⌘T")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func shortcutRow(label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(shortcut)
                .foregroundStyle(.tertiary)
                .monospaced()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Sessions")
                .font(.headline)
            if BackgroundTaskRegistry.shared.runningCount > 0 {
                runningBadge(BackgroundTaskRegistry.shared.runningCount)
            }
            Spacer()
            Button {
                addSession()
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("New Claude session (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func runningBadge(_ count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
            Text("\(count)")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.blue, in: Capsule())
        .help("\(count) background task\(count == 1 ? "" : "s") running")
    }

    private var sessionList: some View {
        List(selection: selectionBinding) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                ClaudeSessionRow(
                    session: session,
                    shortcutNumber: index < 9 ? index + 1 : nil,
                    isSelected: store.selectedSessionID == session.id
                )
                .tag(session.id)
                .contextMenu {
                    Button("Remove", role: .destructive) {
                        store.remove(session)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var emptySidebar: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Click + to add one")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var detail: some View {
        if let id = store.selectedSessionID,
           let session = store.sessions.first(where: { $0.id == id }) {
            ClaudeSessionDetailView(session: session)
                .id(session.id)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(store.sessions.isEmpty ? "No Claude sessions" : "No session selected")
                .font(.headline)
            Text(store.sessions.isEmpty
                ? "Click + to start one in a folder"
                : "Select a session from the sidebar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedSessionID },
            set: { newID in
                guard let newID,
                      let session = store.sessions.first(where: { $0.id == newID })
                else {
                    store.selectedSessionID = nil
                    return
                }
                store.select(session)
            }
        )
    }

    private enum NewSessionChoice {
        case worktree(name: String)
        case useFolderDirectly
    }

    private func addSession() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Pick a git repo to create a worktree from, or any folder to open Claude directly."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sourcePath = url.path

        let base = WorktreeService.repoBaseName(for: url.lastPathComponent)
        guard let choice = promptForNewSession(repoBase: base) else { return }

        switch choice {
        case .useFolderDirectly:
            let session = store.addSession(directory: sourcePath)
            store.select(session)
        case .worktree(let name):
            Task { @MainActor in
                do {
                    let path = try await WorktreeService.create(sourcePath: sourcePath, name: name)
                    let session = store.addSession(directory: path)
                    store.select(session)
                } catch {
                    presentError(error)
                }
            }
        }
    }

    private func promptForNewSession(repoBase: String) -> NewSessionChoice? {
        let alert = NSAlert()
        alert.messageText = "New Claude session"
        alert.informativeText = "Creates a sibling worktree named \(repoBase)--<name> off origin's default branch, after fetching. Or check the box to open Claude in the selected folder directly."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "worktree-name"

        let checkbox = NSButton(
            checkboxWithTitle: "Use this folder directly (no worktree)",
            target: nil,
            action: nil
        )
        let coordinator = WorktreePromptCoordinator(nameField: field)
        checkbox.target = coordinator
        checkbox.action = #selector(WorktreePromptCoordinator.checkboxChanged(_:))

        let stack = NSStackView(views: [field, checkbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        if checkbox.state == .on {
            return .useFolderDirectly
        }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .worktree(name: trimmed)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't create worktree"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Bridges the NSButton checkbox in the new-session alert to the NSTextField
/// so the name field greys out when "use folder directly" is checked. Owned
/// locally by `promptForNewSession` for the duration of the modal because
/// NSControl.target is unowned(unsafe).
private final class WorktreePromptCoordinator: NSObject {
    private weak var nameField: NSTextField?

    init(nameField: NSTextField) {
        self.nameField = nameField
    }

    @objc func checkboxChanged(_ sender: NSButton) {
        nameField?.isEnabled = sender.state != .on
    }
}
#endif
