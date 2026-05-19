#if os(macOS)
import Foundation
import SwiftUI

/// Right-side panel mode for a Claude session. Mutually exclusive: only one
/// pane shows at a time. Stored in AppStorage so the choice persists across
/// app launches. `hidden` lets the terminal use the full width.
enum RightPaneMode: String {
    case hidden
    case diff
    case review

    /// AppStorage key. Shared between the view and the migration helper so
    /// they can't drift.
    static let storageKey = "claude.rightPaneMode"

    /// Old boolean AppStorage key from the diff-only era. The migration
    /// helper translates `true → .diff`, `false → .hidden`, then deletes the
    /// old key so the user's explicit "hide the pane" choice is preserved.
    private static let legacyVisibilityKey = "claude.diffPaneVisible"

    /// Called once at app launch, synchronously from `OdinApp.init` so SwiftUI
    /// never sees the unmigrated state. Idempotent: skips if the new key is
    /// already set or the legacy key was never written. `UserDefaults` is
    /// thread-safe, so this is not pinned to the main actor.
    nonisolated static func migrateLegacyKeyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: legacyVisibilityKey) != nil else { return }
        if defaults.object(forKey: storageKey) == nil {
            let wasVisible = defaults.bool(forKey: legacyVisibilityKey)
            let migrated: RightPaneMode = wasVisible ? .diff : .hidden
            defaults.set(migrated.rawValue, forKey: storageKey)
        }
        defaults.removeObject(forKey: legacyVisibilityKey)
    }
}

/// Per-session review panel state. Owned by `ClaudeSession` so it survives
/// detail-view rebuilds, same as `DiffViewModel`. Findings themselves live on
/// `ReviewRun` in the global `ReviewRunRegistry`; this VM only owns "which run
/// am I showing right now" and the dispatch entry points the panel's buttons
/// call into.
@MainActor
@Observable
final class ReviewViewModel {
    /// If set, the panel shows this specific run even after a newer one starts.
    /// Cleared by `dismiss(parentSessionId:)`. Nil means "track the latest run
    /// for this session".
    var pinnedRunId: String?

    init() {}

    /// Resolves the run the panel should currently show. `nil` → empty state.
    func currentRun(parentSessionId: String?) -> ReviewRun? {
        if let pinnedRunId, let run = ReviewRunRegistry.shared.get(pinnedRunId) {
            return run
        }
        guard let parentSessionId else { return nil }
        return ReviewRunRegistry.shared.latestRun(forSessionId: parentSessionId)
    }

    // MARK: - Fix dispatch

    /// "Fix" button on a location card. Findings are expected to share a file
    /// (and usually a line) since they come from the same card, but we group
    /// defensively by file before dispatching — `FixActionService` spawns one
    /// worker per file so cross-file leakage would race. Findings that aren't
    /// fixable or are already in flight are filtered out; callers don't need
    /// to pre-filter.
    func triggerFix(
        _ findings: [ReviewFinding],
        cwd: String,
        parentSessionId: String?
    ) {
        let dispatchable = findings.filter(\.isDispatchable)
        guard !dispatchable.isEmpty else { return }
        let byFile = Dictionary(grouping: dispatchable, by: \.file)
        for (file, group) in byFile {
            guard let reviewId = group.first?.reviewId else { continue }
            FixActionService.spawn(
                reviewId: reviewId,
                file: file,
                findings: group,
                cwd: cwd,
                parentSessionId: parentSessionId
            )
        }
    }

    /// "Fix all blockers" / "Fix all auto-fixable" header actions. Groups by
    /// file (one worker per file — multiple findings against the same file
    /// would conflict if dispatched separately) and skips findings already
    /// in flight.
    func triggerBulkFix(
        in run: ReviewRun,
        predicate: (ReviewFinding) -> Bool,
        cwd: String,
        parentSessionId: String?
    ) {
        let targets = run.findings.filter { predicate($0) && $0.isDispatchable }
        let byFile = Dictionary(grouping: targets, by: \.file)
        for (file, group) in byFile {
            FixActionService.spawn(
                reviewId: run.id,
                file: file,
                findings: group,
                cwd: cwd,
                parentSessionId: parentSessionId
            )
        }
    }

    /// Drop the current run from the registry. Used by the panel's `Dismiss`
    /// button when the user has acted on what they wanted from this review.
    func dismiss(parentSessionId: String?) {
        guard let run = currentRun(parentSessionId: parentSessionId) else { return }
        ReviewRunRegistry.shared.remove(run.id)
        pinnedRunId = nil
    }
}
#endif
