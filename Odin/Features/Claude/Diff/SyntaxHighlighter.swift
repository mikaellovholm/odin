#if os(macOS)
import AppKit
import Highlightr
import SwiftUI

/// Singleton wrapper around Highlightr. Lazy-initialized because the
/// underlying WKWebView setup is expensive and we don't want to pay it
/// unless the user actually opens the diff pane.
@MainActor
final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private var highlightr: Highlightr?
    private var currentTheme: String = ""
    /// Cache of (language|isDark|line) → AttributedString. Diff lines repeat
    /// (especially `}` and blank lines), so a tiny cache wins a lot.
    private var lineCache: [String: AttributedString] = [:]
    private let cacheLimit = 4_000

    private init() {}

    /// Highlight one logical line of code. Returns plain text on failure or
    /// unknown language so the caller always gets a non-nil result.
    func highlight(line: String, language: String?, isDark: Bool) -> AttributedString {
        let key = "\(language ?? "_")|\(isDark ? "d" : "l")|\(line)"
        if let cached = lineCache[key] { return cached }

        let result = renderLine(line: line, language: language, isDark: isDark)
        if lineCache.count >= cacheLimit {
            lineCache.removeAll(keepingCapacity: true)
        }
        lineCache[key] = result
        return result
    }

    /// Map a file path or extension to a highlight.js language id. Returns
    /// nil if we don't have a confident mapping; the caller will render plain.
    static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "go": return "go"
        case "kt", "kts": return "kotlin"
        case "py": return "python"
        case "ts", "tsx": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "xml"
        case "xml", "plist": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "sh", "bash", "zsh": return "bash"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "java": return "java"
        case "m", "mm": return "objectivec"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp": return "cpp"
        case "toml": return "ini"
        case "sql": return "sql"
        default:
            // Filename-only matches.
            let name = (path as NSString).lastPathComponent.lowercased()
            switch name {
            case "dockerfile": return "dockerfile"
            case "makefile": return "makefile"
            case ".gitignore", ".dockerignore": return "ini"
            default: return nil
            }
        }
    }

    private func renderLine(line: String, language: String?, isDark: Bool) -> AttributedString {
        let theme = isDark ? "atom-one-dark" : "atom-one-light"
        if highlightr == nil {
            highlightr = Highlightr()
        }
        guard let hl = highlightr else { return AttributedString(line) }
        if theme != currentTheme {
            hl.setTheme(to: theme)
            currentTheme = theme
        }
        guard let language,
              let ns = hl.highlight(line, as: language, fastRender: true)
        else {
            return AttributedString(line)
        }
        // Convert NSAttributedString → AttributedString. We strip the explicit
        // background that Highlightr's themes set so the diff's add/remove
        // tint can show through; we keep the foreground colors only.
        return convertKeepingForeground(ns)
    }

    private func convertKeepingForeground(_ ns: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let substring = (ns.string as NSString).substring(with: range)
            var piece = AttributedString(substring)
            if let color = attrs[.foregroundColor] as? NSColor {
                piece.foregroundColor = Color(nsColor: color)
            }
            result.append(piece)
        }
        return result
    }
}
#endif
