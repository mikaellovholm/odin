import SwiftUI
import SwiftData

@main
struct OdinApp: App {
    let container: ModelContainer
    @State private var selectedTab: AppTab = .todos
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
            ThemedContainer {
                ContentView(selectedTab: $selectedTab)
                #if os(macOS)
                    .environment(claudeSessionStore)
                    .task { claudeSessionStore.loadPersisted() }
                #endif
            }
        }
        .modelContainer(container)
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Todo") {
                    selectedTab = .todos
                    NotificationCenter.default.post(name: .odinCreateNewTodo, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("New Note") {
                    selectedTab = .notes
                    NotificationCenter.default.post(name: .odinCreateNewNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Todos") { selectedTab = .todos }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Notes") { selectedTab = .notes }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Terminal") { selectedTab = .terminal }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button("Claude") { selectedTab = .claude }
                    .keyboardShortcut("4", modifiers: [.command, .option])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            ThemedContainer {
                SettingsView()
            }
        }
        #endif
    }
}
