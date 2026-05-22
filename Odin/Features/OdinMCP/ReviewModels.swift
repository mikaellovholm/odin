#if os(macOS)
import Foundation

enum ReviewSeverity: String, CaseIterable, Comparable {
    case blocker
    case major
    case minor
    case nit

    private var order: Int {
        switch self {
        case .blocker: return 0
        case .major: return 1
        case .minor: return 2
        case .nit: return 3
        }
    }

    static func < (lhs: ReviewSeverity, rhs: ReviewSeverity) -> Bool {
        lhs.order < rhs.order
    }
}

/// Lifecycle of a single Phase-1 review concern. Starts `.pending` (the
/// orchestrator declared it but hasn't spawned a worker yet), transitions to
/// `.running` when the worker is launched, then resolves to `.completed` or
/// `.failed`. `.failed` carries a human-readable message so the panel can
/// surface why a concern dropped (worker crash, non-zero exit, etc.).
enum ReviewConcernStatus: Equatable {
    case pending
    case running(taskId: String)
    case completed(taskId: String)
    case failed(taskId: String, message: String)
}

struct ReviewConcern: Identifiable, Equatable {
    /// Concerns are unique per-run by name (correctness, security, …).
    let name: String
    var status: ReviewConcernStatus
    var summary: String?

    var id: String { name }
}

/// Fix lifecycle for a single finding. `.queued` means the panel has dispatched
/// it to a fix worker but the worker hasn't started yet; `.running` carries the
/// fix worker's `task_id` so the UI can correlate back to `ReviewRun.fixes`.
enum FixState: Equatable {
    case none
    case queued
    case running(taskId: String)
    case applied
    case skipped(reason: String)
    case failed(message: String)
}

struct ReviewFinding: Identifiable, Equatable {
    /// `f-<8 hex>`. Generated server-side when `submit_finding` is called so
    /// workers don't have to invent ids.
    let id: String
    let reviewId: String
    let file: String
    let line: Int?
    let severity: ReviewSeverity
    let concern: String
    let title: String
    let detail: String
    let suggestion: String?
    let fixable: Bool
    var fixState: FixState
    let createdAt: Date

    static func makeId() -> String {
        "f-" + UUID().uuidString.prefix(8).lowercased()
    }
}

struct FixWorkerOutcome: Equatable {
    struct Skip: Equatable {
        /// Finding id the worker chose not to apply. Was previously matched by
        /// title — id matching avoids ambiguity when two findings at the same
        /// location share a title (e.g. cross-concern duplicates from the
        /// reviewer fan-out).
        let findingId: String
        let reason: String
    }
    /// Finding ids the worker reports as actually applied (not titles).
    let applied: [String]
    let skipped: [Skip]
    let notes: String?
}

/// One Phase-2 fix worker run. Tied to a single file and the set of findings
/// it was asked to address. `findingIds` is captured at dispatch time so the
/// panel can reflect "this worker is responsible for these findings" even
/// after the underlying findings array mutates.
struct FixWorker: Identifiable, Equatable {
    /// Mirrors the underlying `BackgroundClaudeRunner.id` (`t-<8 hex>`).
    let id: String
    let reviewId: String
    let file: String
    let findingIds: [String]
    var outcome: FixWorkerOutcome?
    var error: String?
    let createdAt: Date
}

@MainActor
@Observable
final class ReviewRun: Identifiable {
    /// `r-<8 hex>`.
    let id: String
    let parentSessionId: String?
    let createdAt: Date
    var diffStat: String?
    var concerns: [ReviewConcern]
    var findings: [ReviewFinding]
    var fixes: [FixWorker]

    init(
        id: String,
        parentSessionId: String?,
        concerns: [String],
        diffStat: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentSessionId = parentSessionId
        self.createdAt = createdAt
        self.diffStat = diffStat
        self.concerns = concerns.map { ReviewConcern(name: $0, status: .pending) }
        self.findings = []
        self.fixes = []
    }

    static func makeId() -> String {
        "r-" + UUID().uuidString.prefix(8).lowercased()
    }
}

/// Attached to `BackgroundClaudeRunner` when the worker is part of a review.
/// Bundled (vs. loose optional fields) so the runner can't be told "this is a
/// reviewer" without also being told its concern.
struct ReviewWorkerContext: Equatable {
    enum Role: Equatable {
        case reviewer(concern: String)
        case fixer(file: String)
    }
    let reviewId: String
    let role: Role
}

// MARK: - Finding predicates

extension ReviewFinding {
    /// "Fix worker dispatch makes sense for this finding": it's marked
    /// fixable AND is in a state we'd actually act on (untouched / previously
    /// failed / previously skipped). The single source of truth shared by the
    /// view model's bulk dispatch path, the location-card Fix button, and the
    /// bulk-action bar's counts.
    var isDispatchable: Bool {
        guard fixable else { return false }
        return isUnfixed
    }

    /// Unfixed regardless of whether the finding is auto-fixable. Used by the
    /// bulk action bar to show "N auto-fixable + M manual" instead of silently
    /// dropping non-fixable findings from the count.
    var isUnfixedAny: Bool {
        isUnfixed
    }

    var isUnfixedBlocker: Bool {
        severity == .blocker && isDispatchable
    }

    var isUnfixedFixable: Bool {
        isDispatchable
    }

    private var isUnfixed: Bool {
        switch fixState {
        case .none, .failed, .skipped: return true
        case .queued, .running, .applied: return false
        }
    }
}
#endif
