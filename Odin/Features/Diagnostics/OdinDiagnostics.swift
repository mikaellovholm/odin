import Foundation

/// Centralised place for Odin to surface "something didn't come up cleanly"
/// to the user. Previously these failures only went to `NSLog`, so the user
/// would discover them as silent missing functionality (no MCP, no hooks,
/// no notifications). Now subscribers (the Claude sidebar banner and the
/// Settings diagnostics row) observe this singleton and render the failure
/// message inline.
///
/// Cross-platform — built on iOS too so `NotificationManager` can talk to it
/// without `#if os(macOS)` guards. The macOS-only subsystems write to it
/// from inside their own `#if os(macOS)` blocks.
@MainActor
@Observable
final class OdinDiagnostics {
    static let shared = OdinDiagnostics()

    enum Status: Equatable {
        case ok
        case failed(String)

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }

        var message: String? {
            if case .failed(let msg) = self { return msg }
            return nil
        }
    }

    /// Loopback MCP server bind / lifecycle.
    var mcpServer: Status = .ok
    /// `OdinHookInstaller.install()` outcome.
    var hooks: Status = .ok
    /// `OdinSkillInstaller.install()` outcome.
    var skills: Status = .ok
    /// `UNUserNotificationCenter` permission / scheduling failures.
    var notifications: Status = .ok

    private init() {}

    /// True iff anything has surfaced a failure. Used by the Claude sidebar
    /// to decide whether to render its banner; cheap to evaluate.
    var hasFailure: Bool {
        !mcpServer.isOK || !hooks.isOK || !skills.isOK || !notifications.isOK
    }

    /// All current failure summaries, in the order the user is most likely
    /// to care about. Empty when everything is healthy.
    var failureSummaries: [(label: String, message: String)] {
        var out: [(String, String)] = []
        if let m = mcpServer.message { out.append(("MCP server", m)) }
        if let m = hooks.message { out.append(("Claude hooks", m)) }
        if let m = skills.message { out.append(("Claude skills", m)) }
        if let m = notifications.message { out.append(("Notifications", m)) }
        return out
    }
}
