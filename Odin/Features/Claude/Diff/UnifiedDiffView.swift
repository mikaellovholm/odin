#if os(macOS)
import SwiftUI

struct UnifiedDiffView: View {
    let file: ChangedFile
    let hunks: [DiffHunk]
    let isBinary: Bool
    let isTruncated: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var language: String? {
        SyntaxHighlighter.language(forPath: file.path)
    }

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        if isBinary {
            placeholder("Binary file — diff not shown")
        } else if hunks.isEmpty {
            placeholder("No textual changes")
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fileHeader
                    ForEach(hunks) { hunk in
                        hunkView(hunk)
                    }
                    if isTruncated {
                        truncationFooter
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 6) {
            Text(file.path)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
            if let old = file.oldPath {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(old)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
    }

    @ViewBuilder
    private func hunkView(_ hunk: DiffHunk) -> some View {
        Text(hunk.header)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.08))

        // Track per-side line numbers across this hunk so the gutter
        // matches what GitHub / VS Code show.
        let numbered = numberLines(hunk: hunk)
        ForEach(numbered) { entry in
            DiffLineRow(
                line: entry.line,
                oldNumber: entry.oldNumber,
                newNumber: entry.newNumber,
                language: language,
                isDark: isDark
            )
        }
    }

    private var truncationFooter: some View {
        Text("Diff truncated at \(DiffViewModel.renderLineCap) lines — open the file in your editor to see the rest.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct NumberedLine: Identifiable {
        let id: String
        let line: DiffLine
        let oldNumber: Int?
        let newNumber: Int?
    }

    private func numberLines(hunk: DiffHunk) -> [NumberedLine] {
        var out: [NumberedLine] = []
        out.reserveCapacity(hunk.lines.count)
        var oldNum = hunk.oldStart
        var newNum = hunk.newStart
        for (idx, line) in hunk.lines.enumerated() {
            let id = "\(hunk.id)-\(idx)"
            switch line {
            case .context:
                out.append(NumberedLine(id: id, line: line, oldNumber: oldNum, newNumber: newNum))
                oldNum += 1
                newNum += 1
            case .addition:
                out.append(NumberedLine(id: id, line: line, oldNumber: nil, newNumber: newNum))
                newNum += 1
            case .deletion:
                out.append(NumberedLine(id: id, line: line, oldNumber: oldNum, newNumber: nil))
                oldNum += 1
            case .hunkHeader, .noNewline:
                out.append(NumberedLine(id: id, line: line, oldNumber: nil, newNumber: nil))
            }
        }
        return out
    }
}

/// One row of the diff. Pulls highlighting from the shared `SyntaxHighlighter`
/// and composites a soft add/remove tint over the result.
private struct DiffLineRow: View {
    let line: DiffLine
    let oldNumber: Int?
    let newNumber: Int?
    let language: String?
    let isDark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(oldNumber)
            gutter(newNumber)
            marker
            content
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tint)
    }

    private func gutter(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: some View {
        Text(markerGlyph)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(markerColor)
            .frame(width: 12, alignment: .center)
    }

    private var markerGlyph: String {
        switch line {
        case .addition: return "+"
        case .deletion: return "−"
        case .noNewline: return "\\"
        default: return " "
        }
    }

    private var markerColor: Color {
        switch line {
        case .addition: return .green
        case .deletion: return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private var content: some View {
        switch line {
        case .context(let s), .addition(let s), .deletion(let s):
            Text(SyntaxHighlighter.shared.highlight(line: s, language: language, isDark: isDark))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        case .hunkHeader(let s):
            Text(s)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        case .noNewline:
            Text(" No newline at end of file")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private var tint: Color {
        switch line {
        case .addition: return Color.green.opacity(0.14)
        case .deletion: return Color.red.opacity(0.14)
        default: return .clear
        }
    }
}
#endif
