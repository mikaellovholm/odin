import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Todos", systemImage: "checklist") {
                TodoListView()
            }
            Tab("Notes", systemImage: "note.text") {
                Text("Notes — coming soon")
                    .foregroundStyle(.secondary)
            }
            Tab("Terminal", systemImage: "terminal") {
                Text("Terminal — coming soon")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
