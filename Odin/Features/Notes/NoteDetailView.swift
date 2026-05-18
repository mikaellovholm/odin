import SwiftUI
import MarkdownUI

struct NoteDetailView: View {
    @Bindable var note: Note
    @State private var showPreview = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var titleFocused: Bool
    @State private var viewWidth: CGFloat = 0

    private var useSideBySide: Bool { viewWidth > 700 }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $note.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .padding(.horizontal)
                .padding(.top, 8)
                .focused($titleFocused)

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
        .toolbar {
            if !useSideBySide {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showPreview.toggle()
                    } label: {
                        Image(systemName: showPreview ? "pencil" : "eye")
                    }
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if note.title.isEmpty && note.content.isEmpty {
                titleFocused = true
            }
        }
        .onChange(of: note.title) { debouncedSave() }
        .onChange(of: note.content) { debouncedSave() }
    }

    private var editorView: some View {
        MarkdownTextEditor(text: $note.content)
            .padding(4)
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

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            note.updatedAt = Date()
        }
    }
}

private struct ViewWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
