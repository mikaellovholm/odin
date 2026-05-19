#if os(macOS)
import Foundation

@MainActor
@Observable
final class ReviewRunRegistry {
    static let shared = ReviewRunRegistry()

    /// In-memory only by design (see plan). Soft cap on retained runs: when
    /// we exceed `maxRetained`, evict the oldest *fully resolved* runs first
    /// (no pending/running concerns, no in-flight fixes). Active runs are
    /// never dropped.
    private let maxRetained = 20

    private(set) var runs: [String: ReviewRun] = [:]

    private init() {}

    // MARK: - Run lifecycle

    @discardableResult
    func startRun(
        parentSessionId: String?,
        concerns: [String],
        diffStat: String?
    ) -> ReviewRun {
        let run = ReviewRun(
            id: ReviewRun.makeId(),
            parentSessionId: parentSessionId,
            concerns: concerns,
            diffStat: diffStat
        )
        runs[run.id] = run
        pruneIfNeeded()
        return run
    }

    func get(_ id: String) -> ReviewRun? {
        runs[id]
    }

    func all() -> [ReviewRun] {
        Array(runs.values)
    }

    /// Most recent run for a given Odin Claude session, by `createdAt`.
    /// Used by the panel to show "the latest review for this tab" without
    /// requiring the UI to track ids itself.
    func latestRun(forSessionId sessionId: String) -> ReviewRun? {
        runs.values
            .filter { $0.parentSessionId == sessionId }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    func remove(_ id: String) {
        runs.removeValue(forKey: id)
    }

    // MARK: - Concern transitions

    /// Marks a concern as running with the given underlying task id. No-op if
    /// the concern doesn't exist on this run — the orchestrator may declare a
    /// different concern set than it actually spawns; we treat the spawn list
    /// as authoritative for "what's running."
    func markConcernRunning(reviewId: String, concern: String, taskId: String) {
        guard let run = runs[reviewId] else { return }
        if let idx = run.concerns.firstIndex(where: { $0.name == concern }) {
            run.concerns[idx].status = .running(taskId: taskId)
        } else {
            run.concerns.append(
                ReviewConcern(name: concern, status: .running(taskId: taskId))
            )
        }
    }

    func markConcernCompleted(
        reviewId: String,
        concern: String,
        taskId: String,
        summary: String?
    ) {
        guard let run = runs[reviewId] else { return }
        guard let idx = run.concerns.firstIndex(where: { $0.name == concern }) else { return }
        run.concerns[idx].status = .completed(taskId: taskId)
        if let summary, !summary.isEmpty {
            run.concerns[idx].summary = summary
        }
    }

    func markConcernFailed(
        reviewId: String,
        concern: String,
        taskId: String,
        message: String
    ) {
        guard let run = runs[reviewId] else { return }
        guard let idx = run.concerns.firstIndex(where: { $0.name == concern }) else { return }
        run.concerns[idx].status = .failed(taskId: taskId, message: message)
    }

    // MARK: - Findings

    /// Appends a finding to its run. Returns the generated finding id so the
    /// MCP tool handler can echo it back to the worker (useful if the worker
    /// later wants to reference a specific finding it submitted).
    @discardableResult
    func appendFinding(
        reviewId: String,
        file: String,
        line: Int?,
        severity: ReviewSeverity,
        concern: String,
        title: String,
        detail: String,
        suggestion: String?,
        fixable: Bool
    ) -> String? {
        guard let run = runs[reviewId] else { return nil }
        let finding = ReviewFinding(
            id: ReviewFinding.makeId(),
            reviewId: reviewId,
            file: file,
            line: line,
            severity: severity,
            concern: concern,
            title: title,
            detail: detail,
            suggestion: suggestion,
            fixable: fixable,
            fixState: .none,
            createdAt: Date()
        )
        run.findings.append(finding)
        return finding.id
    }

    func setFixState(reviewId: String, findingId: String, state: FixState) {
        guard let run = runs[reviewId] else { return }
        guard let idx = run.findings.firstIndex(where: { $0.id == findingId }) else { return }
        run.findings[idx].fixState = state
    }

    // MARK: - Fix workers

    func addFixWorker(
        reviewId: String,
        taskId: String,
        file: String,
        findingIds: [String]
    ) {
        guard let run = runs[reviewId] else { return }
        let worker = FixWorker(
            id: taskId,
            reviewId: reviewId,
            file: file,
            findingIds: findingIds,
            outcome: nil,
            error: nil,
            createdAt: Date()
        )
        run.fixes.append(worker)
        for fid in findingIds {
            setFixState(reviewId: reviewId, findingId: fid, state: .running(taskId: taskId))
        }
    }

    func recordFixOutcome(
        reviewId: String,
        taskId: String,
        outcome: FixWorkerOutcome
    ) {
        guard let run = runs[reviewId] else { return }
        guard let idx = run.fixes.firstIndex(where: { $0.id == taskId }) else { return }
        run.fixes[idx].outcome = outcome
        // Propagate to the underlying findings so the row UI flips without
        // having to cross-reference the fixes array on every render. Matching
        // by finding id (not title) avoids confusion when the same location
        // has multiple findings whose titles collide.
        let scopedIds = Set(run.fixes[idx].findingIds)
        let appliedSet = Set(outcome.applied).intersection(scopedIds)
        // uniquingKeysWith (rather than uniqueKeysWithValues) so a worker that
        // echoes the same finding id twice in `skipped` doesn't trap.
        let skippedById = Dictionary(
            outcome.skipped
                .filter { scopedIds.contains($0.findingId) }
                .map { ($0.findingId, $0.reason) },
            uniquingKeysWith: { _, last in last }
        )
        for fid in run.fixes[idx].findingIds {
            guard let fIdx = run.findings.firstIndex(where: { $0.id == fid }) else { continue }
            if appliedSet.contains(fid) {
                run.findings[fIdx].fixState = .applied
            } else if let reason = skippedById[fid] {
                run.findings[fIdx].fixState = .skipped(reason: reason)
            } else {
                // Worker neither applied nor explicitly skipped — treat as
                // failed so the user notices, instead of leaving the row in a
                // stale `.running` state.
                run.findings[fIdx].fixState = .failed(message: "fix worker did not report an outcome")
            }
        }
    }

    /// Called by `BackgroundClaudeRunner.finish` for a reviewer worker. Never
    /// downgrades a self-reported terminal state — a worker that called
    /// `complete_review_worker` and then crashed should still surface as
    /// completed, not failed.
    func autoResolveReviewerOnExit(
        reviewId: String,
        concern: String,
        taskId: String,
        success: Bool,
        message: String?
    ) {
        guard let run = runs[reviewId] else { return }
        guard let idx = run.concerns.firstIndex(where: { $0.name == concern }) else { return }
        switch run.concerns[idx].status {
        case .completed, .failed:
            return
        case .pending, .running:
            if success {
                run.concerns[idx].status = .completed(taskId: taskId)
            } else {
                run.concerns[idx].status = .failed(
                    taskId: taskId,
                    message: message ?? "worker exited without completion"
                )
            }
        }
    }

    /// Called by `BackgroundClaudeRunner.finish` for a fixer worker. Only acts
    /// if the worker neither reported an outcome nor an error — in that case
    /// it surfaces a synthetic error so the panel doesn't show the worker
    /// stuck in `.running` forever.
    func autoResolveFixerOnExit(
        reviewId: String,
        taskId: String,
        success: Bool,
        message: String?
    ) {
        guard let run = runs[reviewId] else { return }
        guard let idx = run.fixes.firstIndex(where: { $0.id == taskId }) else { return }
        if run.fixes[idx].outcome != nil || run.fixes[idx].error != nil {
            return
        }
        let fallback = message ?? (success ? "fix worker did not submit a result" : "fix worker exited with non-zero status")
        recordFixError(reviewId: reviewId, taskId: taskId, message: fallback)
    }

    func recordFixError(reviewId: String, taskId: String, message: String) {
        guard let run = runs[reviewId] else { return }
        guard let idx = run.fixes.firstIndex(where: { $0.id == taskId }) else { return }
        run.fixes[idx].error = message
        for fid in run.fixes[idx].findingIds {
            setFixState(
                reviewId: reviewId,
                findingId: fid,
                state: .failed(message: message)
            )
        }
    }

    // MARK: - Eviction

    private func pruneIfNeeded() {
        guard runs.count > maxRetained else { return }
        let resolved = runs.values
            .filter { isResolved($0) }
            .sorted { $0.createdAt < $1.createdAt }
        let overflow = runs.count - maxRetained
        for run in resolved.prefix(overflow) {
            runs.removeValue(forKey: run.id)
        }
    }

    private func isResolved(_ run: ReviewRun) -> Bool {
        for concern in run.concerns {
            switch concern.status {
            case .pending, .running:
                return false
            case .completed, .failed:
                continue
            }
        }
        for fix in run.fixes where fix.outcome == nil && fix.error == nil {
            return false
        }
        return true
    }
}
#endif
