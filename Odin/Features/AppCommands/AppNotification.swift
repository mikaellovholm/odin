import Foundation

/// Notification names used to broadcast menu-triggered actions to whichever
/// view is currently mounted (e.g. "create new note" → NoteListView).
extension Notification.Name {
    static let odinCreateNewTodo = Notification.Name("odin.createNewTodo")
    static let odinCreateNewNote = Notification.Name("odin.createNewNote")
    static let odinCreateNewClaudeSession = Notification.Name("odin.createNewClaudeSession")
}
