#if os(macOS)
import Foundation

enum DiffLine: Hashable {
    case context(String)
    case addition(String)
    case deletion(String)
    case hunkHeader(String)
    case noNewline  // "\ No newline at end of file"
}

struct DiffHunk: Hashable, Identifiable {
    let id: Int
    let header: String
    /// Original-file starting line number from the `@@ -a,b +c,d @@` header.
    let oldStart: Int
    /// New-file starting line number from the `@@ -a,b +c,d @@` header.
    let newStart: Int
    let lines: [DiffLine]
}

enum UnifiedDiffParser {
    /// Parse the textual output of `git diff` for a single file into hunks.
    /// File-header lines (`diff --git`, `index`, `+++`, `---`) and any other
    /// non-hunk preamble are dropped — caller already knows which file this is.
    static func parse(_ raw: String) -> [DiffHunk] {
        guard !raw.isEmpty else { return [] }
        var hunks: [DiffHunk] = []
        var current: (header: String, oldStart: Int, newStart: Int, lines: [DiffLine])? = nil
        var hunkId = 0

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                if let c = current {
                    hunks.append(DiffHunk(id: hunkId, header: c.header, oldStart: c.oldStart, newStart: c.newStart, lines: c.lines))
                    hunkId += 1
                }
                let (oldStart, newStart) = parseHunkHeader(line)
                current = (line, oldStart, newStart, [])
                continue
            }
            // Pre-hunk file-header noise: ignore until the first @@.
            guard current != nil else { continue }

            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                current?.lines.append(.addition(String(line.dropFirst())))
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                current?.lines.append(.deletion(String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                current?.lines.append(.noNewline)
            } else if line.hasPrefix(" ") {
                current?.lines.append(.context(String(line.dropFirst())))
            } else if line.isEmpty {
                // A bare empty line inside a hunk is a context line whose
                // leading-space marker was stripped by some tooling. Treat as
                // context.
                current?.lines.append(.context(""))
            }
            // Anything else (e.g. another file-header line) we just skip.
        }
        if let c = current {
            hunks.append(DiffHunk(id: hunkId, header: c.header, oldStart: c.oldStart, newStart: c.newStart, lines: c.lines))
        }
        return hunks
    }

    /// Extracts `oldStart` and `newStart` from `@@ -a,b +c,d @@ optional`.
    /// Missing counts default to 1 per the diff spec.
    private static func parseHunkHeader(_ header: String) -> (Int, Int) {
        // Strip the leading "@@ " and trailing " @@ ..." pieces.
        guard let openEnd = header.range(of: "@@ "),
              let closeStart = header.range(of: " @@", range: openEnd.upperBound..<header.endIndex)
        else { return (0, 0) }
        let inner = header[openEnd.upperBound..<closeStart.lowerBound]
        var oldStart = 0
        var newStart = 0
        for part in inner.split(separator: " ") {
            guard let first = part.first else { continue }
            let body = part.dropFirst() // drop - or +
            let num = body.split(separator: ",").first.flatMap { Int($0) } ?? 0
            if first == "-" { oldStart = num }
            else if first == "+" { newStart = num }
        }
        return (oldStart, newStart)
    }
}
#endif
