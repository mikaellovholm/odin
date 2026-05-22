import SwiftUI
import MarkdownUI

struct NoteDetailView: View {
    @Bindable var note: Note
    @State private var showPreview = false
    /// Tracks whether this editing session has already bumped `updatedAt`. We
    /// bump exactly once per session, on the first edit, so the note jumps to
    /// the top of the sidebar immediately — not on disappear (which made
    /// ⌘1…⌘9 navigation appear to pick the wrong row, because the reshuffle
    /// fired between the shortcut firing and SwiftUI committing the new
    /// selection).
    @State private var didBumpUpdatedAt = false
    @FocusState private var titleFocused: Bool
    @State private var viewWidth: CGFloat = 0

    private var useSideBySide: Bool { viewWidth > 700 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Title", text: $note.title)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                if !useSideBySide {
                    // ⌥⌘M to avoid colliding with FileViewerView's ⇧⌘M
                    // preview toggle — both can be active in the same
                    // window when the Claude tab has the project panel open
                    // alongside the Notes tab.
                    ShortcutKey("⌥⌘M")
                    Button {
                        showPreview.toggle()
                    } label: {
                        Image(systemName: showPreview ? "pencil" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help("Toggle preview (⌥⌘M)")
                    .keyboardShortcut("m", modifiers: [.option, .command])
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()
                .padding(.top, 8)

            if useSideBySide {
                HStack(spacing: 0) {
                    editorView
                    Divider()
                    previewView
                }
            } else if showPreview {
                previewView
            } else {
                editorView
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ViewWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ViewWidthKey.self) { viewWidth = $0 }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if note.title.isEmpty && note.content.isEmpty {
                titleFocused = true
            }
        }
        .onChange(of: note.title) { bumpUpdatedAtOnce() }
        .onChange(of: note.content) { bumpUpdatedAtOnce() }
        // The bump-once flag is scoped to *this note*, not the view-mount.
        // If the user navigates to another note and back inside the same
        // detail-view instance, the flag stays true and a second round of
        // edits wouldn't bump — reset the flag so each note gets its own
        // first-edit bump.
        .onChange(of: note.id) { _, _ in didBumpUpdatedAt = false }
    }

    private var editorView: some View {
        MarkdownTextEditor(text: $note.content)
            .padding(4)
    }

    private func bumpUpdatedAtOnce() {
        guard !didBumpUpdatedAt else { return }
        didBumpUpdatedAt = true
        note.updatedAt = Date()
    }

    private var previewView: some View {
        ScrollView {
            if note.content.isEmpty {
                Text("Nothing to preview")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                Markdown(note.content)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

}

private struct ViewWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Compact shortcut-hint pill. Matches the "esc" indicator in the project-file
/// viewer's header so hints have a consistent look across the app.
struct ShortcutKey: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
            )
    }
}
