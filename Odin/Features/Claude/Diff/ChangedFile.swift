#if os(macOS)
import Foundation

struct ChangedFile: Identifiable, Hashable {
    enum Status: Hashable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case untracked
        case typeChanged
        case unmerged

        var glyph: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .deleted: return "D"
            case .renamed: return "R"
            case .copied: return "C"
            case .untracked: return "?"
            case .typeChanged: return "T"
            case .unmerged: return "U"
            }
        }
    }

    let path: String
    let oldPath: String?
    let status: Status
    let additions: Int
    let deletions: Int
    let isBinary: Bool

    var id: String {
        if let oldPath { return "\(status.glyph):\(oldPath) -> \(path)" }
        return "\(status.glyph):\(path)"
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }

    var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }
}
#endif
