#if os(macOS)
import Foundation

/// One entry in the project file tree. `children` is `nil` for files and
/// non-nil (possibly empty) for directories — matching SwiftUI's
/// `List(_:children:)` convention for distinguishing leaves from branches.
struct ProjectFileNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [ProjectFileNode]?

    var id: String { url.path }
}
#endif
