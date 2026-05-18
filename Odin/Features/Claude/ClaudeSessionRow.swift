#if os(macOS)
import SwiftUI

struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let shortcutNumber: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            Text(session.displayName)
                .font(.body)
            if !session.viewModel.pendingNotifications.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .frame(width: 12, height: 12)
            }
            Spacer()
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private enum SessionStatus {
        case idle           // not running, or selected-and-idle, or fully acknowledged → grey
        case processing     // hook says Claude is working → yellow, pulsing
        case done           // finished a turn but not yet acknowledged → yellow, stable
        case awaitingInput  // Notification hook fired or heartbeat detected a stuck prompt → green
    }

    private var status: SessionStatus {
        let vm = session.viewModel
        guard vm.state == .running else { return .idle }
        // `awaitingInput` trumps both `isActive` (Claude can be "working" by
        // hook while actually blocked on a menu — the heartbeat promotes it
        // here) and `isSelected` (the user might be looking at the prompt but
        // hasn't responded yet).
        if vm.awaitingInput { return .awaitingInput }
        if vm.isActive { return .processing }
        if isSelected { return .idle }
        if vm.didFinish { return .done }
        return .idle
    }

    private var statusColor: Color {
        switch status {
        case .idle: return Color.gray.opacity(0.5)
        case .processing, .done: return .yellow
        case .awaitingInput: return .green
        }
    }

    private var statusDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(statusColor)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .processing)
            .frame(width: 8, height: 8)
    }
}
#endif
