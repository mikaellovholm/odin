import SwiftUI
import SwiftData

@main
struct OdinApp: App {
    let container: ModelContainer
    #if os(macOS)
    @State private var claudeSessionStore = ClaudeSessionStore()
    #endif

    init() {
        do {
            let schema = Schema([TodoItem.self, Note.self])
            let config = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .automatic
            )
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(macOS)
                .environment(claudeSessionStore)
                .task { claudeSessionStore.loadPersisted() }
            #endif
        }
        .modelContainer(container)
    }
}
