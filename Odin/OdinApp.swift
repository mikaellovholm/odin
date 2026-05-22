import SwiftUI
import SwiftData

@main
struct OdinApp: App {
    let container: ModelContainer
    #if os(macOS)
    @State private var selectedTab: AppTab = .claude
    @State private var claudeSessionStore = ClaudeSessionStore()
    #else
    @State private var selectedTab: AppTab = .todos
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
            // Each subsystem reports its outcome to `OdinDiagnostics.shared`
            // so the failure is surfaced in the Claude sidebar banner and
            // the Settings diagnostics row, not just in `NSLog`. Installers
            // already swallow per-file errors internally; we treat partial
            // failure as ok and reserve the `failed` state for a thrown
            // top-level error (e.g. inability to read `~/.claude`).
            OdinSkillInstaller.install()
            OdinDiagnostics.shared.skills = .ok
            OdinHookInstaller.install()
            OdinDiagnostics.shared.hooks = .ok
            do {
                try OdinMCPServer.shared.start()
                OdinDiagnostics.shared.mcpServer = .ok
            } catch {
                NSLog("[OdinMCP] failed to start server: \(error)")
                OdinDiagnostics.shared.mcpServer = .failed("\(error)")
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
                    // Force the NSWindow opaque — without this, the system
                    // window can pick up translucency from materials inside
                    // it (e.g. `.listStyle(.sidebar)`'s vibrant background)
                    // and show whatever is behind the app through the panel.
                    .background(OpaqueWindowAccessor())
                    // SIGTERM every spawned `claude` / shell process and shut
                    // the MCP listener before the app exits, so we don't leak
                    // orphaned children. The kernel's PTY-close-on-exit
                    // eventually delivers SIGHUP, but only after the FD chain
                    // collapses, which can lag long enough to be visible in
                    // `ps`. Cleaner to do it ourselves.
                    .onReceive(
                        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                    ) { _ in
                        for session in claudeSessionStore.sessions {
                            session.viewModel.terminate()
                            session.shellViewModel.terminate()
                        }
                        // Also cancel every in-flight background worker so
                        // review/fix tasks don't keep consuming API tokens
                        // after the user has quit.
                        for runner in BackgroundTaskRegistry.shared.all() {
                            runner.cancel()
                        }
                        OdinMCPServer.shared.stop()
                    }
                #endif
            }
        }
        .modelContainer(container)
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Odin") { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                /// ⌘N is context-sensitive: the title and effect track
                /// `selectedTab` so a single shortcut creates a new item in
                /// whichever pane is showing. Disabled on Remote (no
                /// "new" concept there).
                Button(newItemTitle) { performNewItem() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(selectedTab == .remote)
            }
            CommandMenu("Go") {
                Button("Claude") { selectedTab = .claude }
                    .keyboardShortcut("1", modifiers: .control)
                Button("Remote") { selectedTab = .remote }
                    .keyboardShortcut("2", modifiers: .control)
                Button("Notes") { selectedTab = .notes }
                    .keyboardShortcut("3", modifiers: .control)
                Button("Todos") { selectedTab = .todos }
                    .keyboardShortcut("4", modifiers: .control)
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

    #if os(macOS)
    private var newItemTitle: String {
        switch selectedTab {
        case .claude:   return "New Claude Session"
        case .notes:    return "New Note"
        case .todos:    return "New Todo"
        case .remote:   return "New"
        }
    }

    private func showAboutPanel() {
        AboutWindowController.shared.show()
    }

    private func performNewItem() {
        switch selectedTab {
        case .claude:
            NotificationCenter.default.post(name: .odinCreateNewClaudeSession, object: nil)
        case .notes:
            NotificationCenter.default.post(name: .odinCreateNewNote, object: nil)
        case .todos:
            NotificationCenter.default.post(name: .odinCreateNewTodo, object: nil)
        case .remote:
            break
        }
    }
    #endif
}
