#if os(macOS)
import SwiftUI

struct ChangedFileRow: View {
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 8) {
            statusBadge

            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.parentPath.isEmpty {
                    Text(file.parentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            if file.isBinary {
                Text("bin")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                statCounts
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var statusBadge: some View {
        Text(file.status.glyph)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(statusColor, in: RoundedRectangle(cornerRadius: 3))
    }

    private var statusColor: Color {
        switch file.status {
        case .added, .untracked: return .green
        case .modified, .typeChanged: return .orange
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .unmerged: return .purple
        }
    }

    private var statCounts: some View {
        HStack(spacing: 4) {
            if file.additions > 0 {
                Text("+\(file.additions)")
                    .foregroundStyle(.green)
            }
            if file.deletions > 0 {
                Text("−\(file.deletions)")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 10, design: .monospaced))
    }
}
#endif
