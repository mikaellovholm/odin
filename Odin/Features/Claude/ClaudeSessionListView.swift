#if os(macOS)
import AppKit
import SwiftUI

struct ClaudeSessionListView: View {
    @Environment(ClaudeSessionStore.self) private var store

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 360)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(keyboardShortcuts)
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
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            Text("Claude Sessions")
                .font(.headline)
            Spacer()
            Button {
                addSession()
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("New Claude session")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private func addSession() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude"
        if panel.runModal() == .OK, let url = panel.url {
            let session = store.addSession(directory: url.path)
            store.select(session)
        }
    }
}
#endif
