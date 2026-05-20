import SwiftUI
import SwiftData

struct NoteListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @State private var searchText = ""
    @State private var selectedNote: Note?

    private var filteredNotes: [Note] {
        guard !searchText.isEmpty else { return Array(notes) }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var pinnedNotes: [Note] { filteredNotes.filter(\.isPinned) }
    private var unpinnedNotes: [Note] { filteredNotes.filter { !$0.isPinned } }

    /// Visual order shown in the list: pinned section first, then unpinned.
    /// ⌘1…⌘9 jump to the first nine entries of this combined list.
    private var orderedNotes: [Note] { pinnedNotes + unpinnedNotes }

    /// Map of note ID → ⌘N shortcut index (1-based), populated for the first
    /// nine visible notes. Built once per body eval so per-row lookups are
    /// O(1) instead of O(n) via `firstIndex` — matters once the list grows
    /// past a few dozen entries.
    private var shortcutNumbers: [UUID: Int] {
        var result: [UUID: Int] = [:]
        for (index, note) in orderedNotes.prefix(9).enumerated() {
            result[note.id] = index + 1
        }
        return result
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    /// HSplitView mirrors the Claude Sessions layout (fixed sidebar that can't
    /// be hidden, custom in-sidebar header). Pulls Notes off NavigationSplitView
    /// so the user can't collapse the panel via the toolbar toggle.
    private var macBody: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 400)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(keyboardShortcuts)
        .onReceive(NotificationCenter.default.publisher(for: .odinCreateNewNote)) { _ in
            createNote()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            if filteredNotes.isEmpty {
                emptySidebar
            } else {
                notesList
            }
            Divider()
            shortcutHints
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Notes")
                .font(.headline)
            Spacer()
            CloudKitSyncStatusView()
            Button { createNote() } label: {
                Image(systemName: "plus")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("New note (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search notes", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var notesList: some View {
        List(selection: $selectedNote) {
            if !pinnedNotes.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedNotes) { note in
                        NoteRow(
                            note: note,
                            shortcutNumber: shortcutNumbers[note.id],
                            pinAction: "Unpin",
                            pinImage: "pin.slash",
                            newPinState: false,
                            onDelete: { modelContext.delete(note) }
                        )
                        .tag(note)
                    }
                }
            }

            Section {
                ForEach(unpinnedNotes) { note in
                    NoteRow(
                        note: note,
                        shortcutNumber: shortcutNumbers[note.id],
                        pinAction: "Pin",
                        pinImage: "pin",
                        newPinState: true,
                        onDelete: { modelContext.delete(note) }
                    )
                    .tag(note)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var emptySidebar: some View {
        VStack(spacing: 8) {
            Text(searchText.isEmpty ? "No notes" : "No matches")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "Click + to create one" : "Try a different search")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var detail: some View {
        if let note = selectedNote {
            NoteDetailView(note: note)
                .id(note.id)
        } else {
            emptyDetail
        }
    }

    /// Mirrors the Claude Sessions empty-detail layout: small icon, headline,
    /// secondary subtitle — instead of `ContentUnavailableView`'s much larger
    /// system styling.
    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(notes.isEmpty ? "No notes" : "Select a note")
                .font(.headline)
            Text(notes.isEmpty
                 ? "Click + to create one"
                 : "Select a note from the sidebar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
    }

    private var shortcutHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            shortcutRow(label: "New note", shortcut: "⌘N")
            shortcutRow(label: "Jump to note", shortcut: "⌘1–9")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Hidden buttons that register ⌘1…⌘9 as shortcuts for the first nine
    /// notes in visual order (pinned first, then unpinned).
    private var keyboardShortcuts: some View {
        ZStack {
            ForEach(Array(orderedNotes.prefix(9).enumerated()), id: \.element.id) { index, note in
                Button("") { selectedNote = note }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }
    #endif

    // MARK: - iOS

    #if !os(macOS)
    private var iosBody: some View {
        NavigationSplitView {
            List(selection: $selectedNote) {
                if !pinnedNotes.isEmpty {
                    Section("Pinned") {
                        ForEach(pinnedNotes) { note in
                            NoteRow(
                                note: note,
                                shortcutNumber: nil,
                                pinAction: "Unpin",
                                pinImage: "pin.slash",
                                newPinState: false,
                                onDelete: { modelContext.delete(note) }
                            )
                            .tag(note)
                        }
                    }
                }

                Section {
                    ForEach(unpinnedNotes) { note in
                        NoteRow(
                            note: note,
                            shortcutNumber: nil,
                            pinAction: "Pin",
                            pinImage: "pin",
                            newPinState: true,
                            onDelete: { modelContext.delete(note) }
                        )
                        .tag(note)
                    }
                }
            }
            .navigationTitle("Notes")
            .searchable(text: $searchText, prompt: "Search notes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { createNote() } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    CloudKitSyncStatusView()
                }
            }
            .overlay {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "note.text",
                        description: Text("Tap + to create a note")
                    )
                }
            }
        } detail: {
            if let note = selectedNote {
                NoteDetailView(note: note)
            } else {
                ContentUnavailableView("Select a Note", systemImage: "note.text")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .odinCreateNewNote)) { _ in
            createNote()
        }
    }
    #endif

    private func createNote() {
        let note = Note()
        modelContext.insert(note)
        selectedNote = note
    }
}

/// Single note row. macOS shows the inline `⌘N` shortcut hint and `x` remove
/// button on the trailing edge; iOS hides those (no hardware shortcuts there).
/// Lives outside the navigation hierarchy so the `x` button is independently
/// tappable inside the row.
private struct NoteRow: View {
    @Bindable var note: Note
    let shortcutNumber: Int?
    let pinAction: String
    let pinImage: String
    let newPinState: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .lineLimit(1)

                if !note.content.isEmpty {
                    Text(note.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(note.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            #if os(macOS)
            Spacer()
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            removeButton
            #endif
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button { note.isPinned = newPinState } label: {
                Label(pinAction, systemImage: pinImage)
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { note.isPinned = newPinState } label: {
                Label(pinAction, systemImage: pinImage)
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    #if os(macOS)
    private var removeButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete note")
    }
    #endif
}
