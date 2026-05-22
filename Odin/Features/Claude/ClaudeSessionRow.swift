#if os(macOS)
import SwiftUI

struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let shortcutNumber: Int?
    let isSelected: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            Text(session.displayName)
                .font(.body)
            Spacer()
            activityIndicator
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            removeButton
        }
        .padding(.vertical, 2)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove session")
    }

    @ViewBuilder
    private var activityIndicator: some View {
        HStack(spacing: 4) {
            if session.viewModel.activeSubagents > 0 {
                subagentBadge(count: session.viewModel.activeSubagents)
            }
            if !session.viewModel.pendingNotifications.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .frame(width: 12, height: 12)
            } else if let count = runningTaskCount, count > 0 {
                Text("🤔")
                    .font(.caption)
                    .help("\(count) background task\(count == 1 ? "" : "s") running")
            }
        }
    }

    private func subagentBadge(count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9))
            Text("\(count)")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .help("\(count) subagent\(count == 1 ? "" : "s") running")
    }

    private enum SessionStatus {
        case idle               // not running, or selected-and-idle, or fully acknowledged → grey
        case processing         // hook says Claude is working → yellow, pulsing
        case compacting         // PreCompact fired, PostCompact has not → orange, pulsing
        case done               // finished a turn but not yet acknowledged → yellow, stable
        case awaitingInput      // Notification hook / heartbeat-promoted stuck prompt → green
        case awaitingPermission // PermissionRequest hook → green, highest urgency
    }

    private var status: SessionStatus {
        let vm = session.viewModel
        guard vm.state == .running else { return .idle }
        // Permission outranks everything: the user can clear it with one
        // keystroke and the cost of missing it is highest.
        if vm.awaitingPermission { return .awaitingPermission }
        // `awaitingInput` still trumps `isActive`/`isSelected` for the same
        // reason it did before — looking at a prompt isn't responding to it.
        if vm.awaitingInput { return .awaitingInput }
        if vm.isCompacting { return .compacting }
        if vm.isActive { return .processing }
        if isSelected { return .idle }
        if vm.didFinish { return .done }
        return .idle
    }

    private var statusColor: Color {
        switch status {
        case .idle: return Color.gray.opacity(0.5)
        case .processing, .done: return .yellow
        case .compacting: return .orange
        case .awaitingInput, .awaitingPermission: return .green
        }
    }

    private var runningTaskCount: Int? {
        guard let id = session.viewModel.sessionId else { return nil }
        return BackgroundTaskRegistry.shared.runningCount(forSessionId: id)
    }

    private var statusDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(statusColor)
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: status == .processing || status == .compacting
            )
            .frame(width: 8, height: 8)
    }
}
#endif
