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

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedNote) {
                if !pinnedNotes.isEmpty {
                    Section("Pinned") {
                        ForEach(pinnedNotes) { note in
                            noteLink(note, pinAction: "Unpin", pinImage: "pin.slash", newPinState: false)
                        }
                    }
                }

                Section {
                    ForEach(unpinnedNotes) { note in
                        noteLink(note, pinAction: "Pin", pinImage: "pin", newPinState: true)
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

    private func noteLink(_ note: Note, pinAction: String, pinImage: String, newPinState: Bool) -> some View {
        NavigationLink(value: note) {
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
        }
        .swipeActions(edge: .leading) {
            Button { note.isPinned = newPinState } label: {
                Label(pinAction, systemImage: pinImage)
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { modelContext.delete(note) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func createNote() {
        let note = Note()
        modelContext.insert(note)
        selectedNote = note
    }
}
