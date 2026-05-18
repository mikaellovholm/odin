import SwiftUI

/// Persisted terminal font size, shared by the SSH terminal and Claude terminal.
/// iOS and macOS each carry their own preferred size — iPhones want ~10 pt,
/// Macs ~12. Values clamp to a sensible legibility range.
enum TerminalFontSettings {
    #if os(iOS)
    static let key = "terminal.fontSize.iOS"
    static let defaultSize: CGFloat = 10
    #else
    static let key = "terminal.fontSize.macOS"
    static let defaultSize: CGFloat = 12
    #endif

    static let minSize: CGFloat = 6
    static let maxSize: CGFloat = 28
    static let step: CGFloat = 1
}
