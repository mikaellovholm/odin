import SwiftUI
import SwiftData

@main
struct OdinApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [TodoItem.self])
    }
}
