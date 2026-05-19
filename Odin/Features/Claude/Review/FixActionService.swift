#if os(macOS)
import Foundation

/// Spawns Phase-2 fix workers from the review panel. Mirrors how the
/// orchestrator's `run_background_task` call would do it, but stays on the
/// Swift side — clicking Fix in the panel doesn't bother the in-tab Claude
/// session. The worker gets MCP access via `BackgroundClaudeRunner`'s per-
/// worker `.mcp.json`; it reports back through `mcp__odin__submit_fix_result`.
@MainActor
enum FixActionService {
    /// Pinned model for all review/fix workers — see `odin-review` SKILL.md.
    private static let workerModel = "claude-sonnet-4-6"

    /// Findings whose fix was requested while another worker was already in
    /// flight for the same file. Drained by `workerCompleted` when that worker
    /// exits. Keyed by `<reviewId>|<file>` so multiple parallel reviews don't
    /// collide.
    private struct PendingBatch {
        var findings: [ReviewFinding]
        let cwd: String
        let parentSessionId: String?
    }
    private static var pending: [String: PendingBatch] = [:]

    static func spawn(
        reviewId: String,
        file: String,
        findings: [ReviewFinding],
        cwd: String,
        parentSessionId: String?
    ) {
        guard !findings.isEmpty else { return }
        let key = pendingKey(reviewId: reviewId, file: file)

        // Per-file lock. If a fix worker is already in flight for this file,
        // queue these findings and let `workerCompleted` re-dispatch them when
        // the current worker exits. The user still gets immediate `.queued`
        // feedback on the rows so it doesn't look like the click was ignored.
        if isFileBusy(reviewId: reviewId, file: file) {
            markQueued(reviewId: reviewId, findings: findings)
            if var batch = pending[key] {
                let existingIds = Set(batch.findings.map(\.id))
                let toAdd = findings.filter { !existingIds.contains($0.id) }
                batch.findings.append(contentsOf: toAdd)
                pending[key] = batch
            } else {
                pending[key] = PendingBatch(
                    findings: findings,
                    cwd: cwd,
                    parentSessionId: parentSessionId
                )
            }
            return
        }

        markQueued(reviewId: reviewId, findings: findings)

        let prompt = buildPrompt(file: file, findings: findings)
        do {
            let runner = try BackgroundTaskRegistry.shared.create(
                prompt: prompt,
                cwd: cwd,
                parentSessionId: parentSessionId,
                model: workerModel,
                reviewContext: ReviewWorkerContext(
                    reviewId: reviewId,
                    role: .fixer(file: file)
                )
            )
            // Register the fix worker only after the spawn succeeded — same
            // policy as the reviewer path in `OdinMCPTools.runBackgroundTask`.
            ReviewRunRegistry.shared.addFixWorker(
                reviewId: reviewId,
                taskId: runner.id,
                file: file,
                findingIds: findings.map { $0.id }
            )
            // Chain onto BackgroundTaskRegistry's existing onFinish (it
            // decrements the running count) so we can drain the pending queue
            // for this file as soon as the worker exits.
            let previous = runner.onFinish
            runner.onFinish = { state in
                previous?(state)
                Task { @MainActor in
                    FixActionService.workerCompleted(reviewId: reviewId, file: file)
                }
            }
        } catch {
            let message = "failed to spawn fix worker: \(error)"
            for finding in findings {
                ReviewRunRegistry.shared.setFixState(
                    reviewId: reviewId,
                    findingId: finding.id,
                    state: .failed(message: message)
                )
            }
        }
    }

    /// Called from the chained `onFinish` after a fix worker exits. Drains the
    /// pending queue for the just-freed file. We re-filter against the live
    /// registry state so findings that the previous worker happened to address
    /// (e.g. an overlapping fix) don't get re-dispatched unnecessarily.
    private static func workerCompleted(reviewId: String, file: String) {
        let key = pendingKey(reviewId: reviewId, file: file)
        guard let batch = pending.removeValue(forKey: key) else { return }
        guard let run = ReviewRunRegistry.shared.get(reviewId) else { return }
        let stillNeedsFix = batch.findings.compactMap { staleFinding -> ReviewFinding? in
            guard let live = run.findings.first(where: { $0.id == staleFinding.id }) else {
                return nil
            }
            switch live.fixState {
            case .none, .queued, .failed, .skipped:
                return live
            case .running, .applied:
                return nil
            }
        }
        guard !stillNeedsFix.isEmpty else { return }
        spawn(
            reviewId: reviewId,
            file: file,
            findings: stillNeedsFix,
            cwd: batch.cwd,
            parentSessionId: batch.parentSessionId
        )
    }

    private static func isFileBusy(reviewId: String, file: String) -> Bool {
        guard let run = ReviewRunRegistry.shared.get(reviewId) else { return false }
        return run.fixes.contains { fix in
            fix.file == file && fix.outcome == nil && fix.error == nil
        }
    }

    private static func markQueued(reviewId: String, findings: [ReviewFinding]) {
        for finding in findings {
            ReviewRunRegistry.shared.setFixState(
                reviewId: reviewId,
                findingId: finding.id,
                state: .queued
            )
        }
    }

    private static func pendingKey(reviewId: String, file: String) -> String {
        "\(reviewId)|\(file)"
    }

    private static func buildPrompt(file: String, findings: [ReviewFinding]) -> String {
        let findingObjects: [[String: Any]] = findings.map { f in
            var dict: [String: Any] = [
                "id": f.id,
                "title": f.title,
                "severity": f.severity.rawValue,
                "concern": f.concern,
                "detail": f.detail,
                "fixable": f.fixable
            ]
            if let line = f.line { dict["line"] = line }
            if let suggestion = f.suggestion { dict["suggestion"] = suggestion }
            return dict
        }
        let findingsJSON = (try? JSONSerialization.data(
            withJSONObject: findingObjects,
            options: [.prettyPrinted, .sortedKeys]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return """
        You are applying review fixes to a single file. You ARE authorized to edit this file.

        File: \(file)
        You may edit ONLY this file. Do not touch any other path.

        Findings to address (JSON array). Each finding has an `id` you must use when reporting back:
        \(findingsJSON)

        For each finding:
        1. Open the file and locate the issue. Use the `line` hint if provided.
        2. Apply the smallest change that resolves it. If `suggestion` is concrete, prefer it.
        3. Do not refactor unrelated code. Do not add tests unless a finding explicitly asks.
        4. If a finding is wrong on inspection (false positive), skip it and explain why.

        When done, call mcp__odin__submit_fix_result with:
          - applied: array of finding `id` values you actually fixed (NOT titles — use the id field)
          - skipped: array of {finding_id, reason} for findings you deliberately did NOT apply
          - notes: optional free-form note for the user

        Then reply with just the string "DONE".
        """
    }
}
#endif
