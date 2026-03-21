import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Todos", systemImage: "checklist") {
                TodoListView()
            }
            Tab("Notes", systemImage: "note.text") {
                NoteListView()
            }
            Tab("Terminal", systemImage: "terminal") {
                Text("Terminal — coming soon")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
