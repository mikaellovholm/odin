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

        #if os(macOS)
        Task { @MainActor in
            OdinSkillInstaller.install()
            OdinHookInstaller.install()
            do {
                try OdinMCPServer.shared.start()
            } catch {
                NSLog("[OdinMCP] failed to start server: \(error)")
            }
        }
        #endif
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
