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
    /// Cleared by `unpin()` and by `dismiss()`. Nil means "track the latest".
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
        let dispatchable = findings.filter(shouldDispatch)
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
        let targets = run.findings.filter { predicate($0) && shouldDispatch($0) }
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

    /// Whether `triggerFix` should actually spawn a worker for this finding.
    /// Keeping this in one place so single-fix and bulk-fix agree.
    private func shouldDispatch(_ finding: ReviewFinding) -> Bool {
        guard finding.fixable else { return false }
        switch finding.fixState {
        case .none, .failed, .skipped:
            return true
        case .queued, .running, .applied:
            return false
        }
    }
}
#endif
