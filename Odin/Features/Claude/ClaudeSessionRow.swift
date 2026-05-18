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
            if let count = runningTaskCount, count > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.blue)
                .help("\(count) background task\(count == 1 ? "" : "s") running")
            }
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var runningTaskCount: Int? {
        guard let id = session.viewModel.sessionId else { return nil }
        return BackgroundTaskRegistry.shared.runningCount(forSessionId: id)
    }

    @ViewBuilder
    private var statusDot: some View {
        if !session.viewModel.pendingNotifications.isEmpty {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .frame(width: 12, height: 12)
        } else {
            Circle()
                .fill(session.viewModel.isActive ? Color.green : .clear)
                .frame(width: 8, height: 8)
        }
    }
}
#endif
