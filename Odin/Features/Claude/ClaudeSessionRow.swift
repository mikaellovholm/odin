#if os(macOS)
import SwiftUI

struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let shortcutNumber: Int?

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            Text(session.displayName)
                .font(.body)
            Spacer()
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(session.viewModel.isActive ? Color.green : .clear)
            .frame(width: 8, height: 8)
    }
}
#endif
