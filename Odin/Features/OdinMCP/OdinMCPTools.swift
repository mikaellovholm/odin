#if os(macOS)
import Foundation

enum OdinMCPTools {
    static let descriptors: [[String: Any]] = [
        [
            "name": "run_background_task",
            "description": """
            Spawn a headless Claude Code session in the background to perform a single task. \
            Returns immediately with a task_id. Use await_task to retrieve the result, or \
            get_task_status to poll without blocking. The background session has no UI and \
            runs with --dangerously-skip-permissions, so scope its prompt narrowly. \
            For odin-review reviewer workers, pass review_id (from start_review_run) and \
            concern — the worker then gets MCP access to submit_finding/complete_review_worker.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description": "The prompt the background session will execute. Be specific about the expected output format."
                    ],
                    "cwd": [
                        "type": "string",
                        "description": "Working directory for the background session. Defaults to the user's home directory."
                    ],
                    "model": [
                        "type": "string",
                        "description": "Optional Claude model id to pin for this worker (e.g. 'claude-sonnet-4-6', 'claude-opus-4-7', 'claude-haiku-4-5'). Omit to use the host claude CLI's default model."
                    ],
                    "review_id": [
                        "type": "string",
                        "description": "Optional. Id returned by start_review_run. When set together with `concern`, the worker is registered as a Phase-1 reviewer and given MCP access to submit_finding/complete_review_worker."
                    ],
                    "concern": [
                        "type": "string",
                        "description": "Optional. Required when review_id is set. One of correctness / security / tests / style / performance / api-compat (or any single concern name your review run declared)."
                    ]
                ],
                "required": ["prompt"]
            ]
        ],
        [
            "name": "get_task_status",
            "description": "Check the status of a background task without blocking. Returns running, completed, or failed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task_id": ["type": "string", "description": "The id returned by run_background_task."]
                ],
                "required": ["task_id"]
            ]
        ],
        [
            "name": "await_task",
            "description": "Block until a background task finishes (or timeout_seconds elapses) and return its result.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task_id": ["type": "string", "description": "The id returned by run_background_task."],
                    "timeout_seconds": [
                        "type": "number",
                        "description": "Maximum seconds to wait. Defaults to 300 (5 minutes)."
                    ]
                ],
                "required": ["task_id"]
            ]
        ],
        [
            "name": "start_review_run",
            "description": """
            Start a structured review run owned by Odin. Returns a review_id you then pass to \
            run_background_task for each Phase-1 reviewer worker. Workers spawned this way get \
            MCP access to submit_finding and complete_review_worker so Odin can render their \
            findings live in the review pane.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "concerns": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Names of the concerns you intend to spawn workers for (e.g. ['correctness','security','tests','style']). Order is preserved in the panel."
                    ],
                    "diff_stat": [
                        "type": "string",
                        "description": "Optional one-line summary of the diff under review (e.g. output of `git diff --stat | tail -1`). Shown in the panel header."
                    ]
                ],
                "required": ["concerns"]
            ]
        ],
        [
            "name": "submit_finding",
            "description": """
            Called by a Phase-1 reviewer worker to report one finding. The review_id and concern \
            are read from the worker's MCP headers — you don't pass them explicitly. Returns a \
            finding_id which appears in the review pane immediately.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "file":        ["type": "string", "description": "Path of the file the finding applies to (relative to the worktree root)."],
                    "line":        ["type": "integer", "description": "Optional 1-based line number in the post-change file."],
                    "severity":    ["type": "string", "description": "One of: blocker, major, minor, nit."],
                    "title":       ["type": "string", "description": "One-line summary."],
                    "detail":      ["type": "string", "description": "One paragraph: what's wrong and why."],
                    "suggestion":  ["type": "string", "description": "Optional concrete change. Omit if no single edit clearly resolves it."],
                    "fixable":     ["type": "boolean", "description": "True only if a single-file edit clearly resolves the finding."],
                    "concern":     ["type": "string", "description": "Optional. Defaults to the worker's own concern from MCP headers. Override only if reporting a cross-concern finding."]
                ],
                "required": ["file", "severity", "title", "detail", "fixable"]
            ]
        ],
        [
            "name": "complete_review_worker",
            "description": """
            Called by a Phase-1 reviewer worker when it's done emitting findings. The review_id, \
            concern, and task_id are read from MCP headers. Optional `summary` shows up in the \
            panel under the concern header. Calling this is idempotent and not strictly required — \
            the worker exiting with code 0 implies completion too — but it lets you flag an \
            empty result ("no findings") explicitly.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "Optional one-line summary of what was checked."]
                ],
                "required": []
            ]
        ],
        [
            "name": "get_review_run",
            "description": """
            Read back the current state of a review run — concerns + statuses, all submitted findings, and \
            fix-worker results. Call this when the user asks about a specific finding ("explain the blocker", \
            "what did security flag", "which findings are still open"). When called with no `review_id`, \
            returns the latest review run for your tab (the X-Session-Id header). Do NOT call this proactively \
            after dispatching reviewers — the review pane already shows findings live; only fetch when the user \
            asks a question.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "review_id": [
                        "type": "string",
                        "description": "Optional. Id returned by start_review_run. Omit to get the latest run for this tab."
                    ]
                ],
                "required": []
            ]
        ],
        [
            "name": "submit_fix_result",
            "description": """
            Called by a Phase-2 fix worker when it's done editing. The review_id and task_id are \
            read from MCP headers. Findings the worker fixed go in `applied` by finding_id; findings \
            deliberately not touched go in `skipped` with a reason. Findings the worker doesn't \
            mention will be surfaced as failed in the panel. Ids outside the worker's scope are \
            ignored — you can only flip findings you were dispatched for.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "applied": [
                        "type": "array",
                        "items": [
                            "type": "string",
                            "description": "A finding id, e.g. 'f-abcd1234'."
                        ],
                        "description": "Finding ids (the `id` field from each finding in your prompt) that the worker actually fixed in this run."
                    ],
                    "skipped": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "finding_id": ["type": "string"],
                                "reason":     ["type": "string"]
                            ],
                            "required": ["finding_id", "reason"]
                        ],
                        "description": "Findings the worker deliberately did not apply (false positive, needs human, etc.). Use the `id` field, not the title."
                    ],
                    "notes": ["type": "string", "description": "Optional free-form note shown alongside the fix worker's status."]
                ],
                "required": ["applied"]
            ]
        ]
    ]

    @MainActor
    static func call(name: String, args: [String: Any]) async throws -> String {
        switch name {
        case "run_background_task":
            return try runBackgroundTask(args)
        case "get_task_status":
            return try getTaskStatus(args)
        case "await_task":
            return try await awaitTask(args)
        case "start_review_run":
            return try startReviewRun(args)
        case "submit_finding":
            return try submitFinding(args)
        case "complete_review_worker":
            return try completeReviewWorker(args)
        case "submit_fix_result":
            return try submitFixResult(args)
        case "get_review_run":
            return try getReviewRun(args)
        default:
            throw OdinMCPError.invalidArgument("unknown tool: \(name)")
        }
    }

    @MainActor
    private static func runBackgroundTask(_ args: [String: Any]) throws -> String {
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            throw OdinMCPError.invalidArgument("prompt is required")
        }
        let cwd = (args["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let model = (args["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let reviewId = (args["review_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let concern = (args["concern"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var reviewContext: ReviewWorkerContext?
        if let reviewId {
            guard let concern else {
                throw OdinMCPError.invalidArgument("concern is required when review_id is set")
            }
            guard ReviewRunRegistry.shared.get(reviewId) != nil else {
                throw OdinMCPError.invalidArgument("review run not found: \(reviewId)")
            }
            reviewContext = ReviewWorkerContext(
                reviewId: reviewId,
                role: .reviewer(concern: concern)
            )
        }

        let runner = try BackgroundTaskRegistry.shared.create(
            prompt: prompt,
            cwd: cwd,
            parentSessionId: CurrentMCPRequest.sessionId,
            model: model,
            reviewContext: reviewContext
        )

        // Register the concern as running only after the spawn succeeded, so a
        // crashed spawn doesn't leave a phantom "running" concern in the panel.
        if let reviewId, let concern {
            ReviewRunRegistry.shared.markConcernRunning(
                reviewId: reviewId,
                concern: concern,
                taskId: runner.id
            )
        }

        var response: [String: Any] = [
            "task_id": runner.id,
            "status": "running",
            "cwd": cwd
        ]
        if let model {
            response["model"] = model
        }
        if let reviewId {
            response["review_id"] = reviewId
        }
        if let concern {
            response["concern"] = concern
        }
        return jsonString(response)
    }

    @MainActor
    private static func startReviewRun(_ args: [String: Any]) throws -> String {
        guard let concernsRaw = args["concerns"] as? [Any], !concernsRaw.isEmpty else {
            throw OdinMCPError.invalidArgument("concerns is required (non-empty array of strings)")
        }
        let concerns: [String] = concernsRaw.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !concerns.isEmpty else {
            throw OdinMCPError.invalidArgument("concerns must contain at least one non-empty string")
        }
        let diffStat = (args["diff_stat"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let run = ReviewRunRegistry.shared.startRun(
            parentSessionId: CurrentMCPRequest.sessionId,
            concerns: concerns,
            diffStat: diffStat
        )
        return jsonString([
            "review_id": run.id,
            "concerns": concerns
        ])
    }

    @MainActor
    private static func submitFinding(_ args: [String: Any]) throws -> String {
        guard let reviewId = CurrentMCPRequest.reviewId, !reviewId.isEmpty else {
            throw OdinMCPError.invalidArgument("submit_finding requires X-Review-Id header (only callable from a review worker)")
        }
        guard ReviewRunRegistry.shared.get(reviewId) != nil else {
            throw OdinMCPError.invalidArgument("review run not found: \(reviewId)")
        }
        guard let file = args["file"] as? String, !file.isEmpty else {
            throw OdinMCPError.invalidArgument("file is required")
        }
        guard let title = args["title"] as? String, !title.isEmpty else {
            throw OdinMCPError.invalidArgument("title is required")
        }
        guard let detail = args["detail"] as? String, !detail.isEmpty else {
            throw OdinMCPError.invalidArgument("detail is required")
        }
        guard let severityRaw = args["severity"] as? String,
              let severity = ReviewSeverity(rawValue: severityRaw.lowercased()) else {
            throw OdinMCPError.invalidArgument("severity must be one of: blocker, major, minor, nit")
        }
        guard let fixable = args["fixable"] as? Bool else {
            throw OdinMCPError.invalidArgument("fixable is required (boolean)")
        }
        let concern = (args["concern"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? CurrentMCPRequest.concern
        guard let concern, !concern.isEmpty else {
            throw OdinMCPError.invalidArgument("concern is required (set X-Concern header or pass `concern` arg)")
        }
        // Tolerate `line: 0` as "no line" — workers occasionally emit it for
        // file-level findings.
        let line: Int? = {
            if let n = args["line"] as? Int, n > 0 { return n }
            if let n = args["line"] as? Double, n > 0 { return Int(n) }
            return nil
        }()
        let suggestion = (args["suggestion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let findingId = ReviewRunRegistry.shared.appendFinding(
            reviewId: reviewId,
            file: file,
            line: line,
            severity: severity,
            concern: concern,
            title: title,
            detail: detail,
            suggestion: suggestion,
            fixable: fixable
        ) else {
            throw OdinMCPError.invalidArgument("failed to append finding (review run gone?)")
        }
        return jsonString(["ok": true, "finding_id": findingId])
    }

    @MainActor
    private static func completeReviewWorker(_ args: [String: Any]) throws -> String {
        guard let reviewId = CurrentMCPRequest.reviewId, !reviewId.isEmpty else {
            throw OdinMCPError.invalidArgument("complete_review_worker requires X-Review-Id header")
        }
        guard let concern = CurrentMCPRequest.concern, !concern.isEmpty else {
            throw OdinMCPError.invalidArgument("complete_review_worker requires X-Concern header")
        }
        guard let taskId = CurrentMCPRequest.taskId, !taskId.isEmpty else {
            throw OdinMCPError.invalidArgument("complete_review_worker requires X-Task-Id header")
        }
        let summary = (args["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ReviewRunRegistry.shared.markConcernCompleted(
            reviewId: reviewId,
            concern: concern,
            taskId: taskId,
            summary: summary
        )
        return jsonString(["ok": true])
    }

    @MainActor
    private static func getReviewRun(_ args: [String: Any]) throws -> String {
        let explicitId = (args["review_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let run: ReviewRun?
        if let explicitId {
            run = ReviewRunRegistry.shared.get(explicitId)
        } else if let sid = CurrentMCPRequest.sessionId, !sid.isEmpty {
            run = ReviewRunRegistry.shared.latestRun(forSessionId: sid)
        } else {
            run = nil
        }
        guard let run else {
            return jsonString([
                "review_id": NSNull(),
                "message": "no review run found"
            ])
        }
        return jsonString(serialize(run: run))
    }

    /// Shared ISO-8601 formatter for `get_review_run` payloads. `ISO8601DateFormatter`
    /// is documented thread-safe for formatting; hoisting it here saves the per-call
    /// allocation in `serialize(run:)`, which can fire on every user question about
    /// a long-running review.
    private static let isoFormatter = ISO8601DateFormatter()

    @MainActor
    private static func serialize(run: ReviewRun) -> [String: Any] {
        let iso = OdinMCPTools.isoFormatter
        let concerns: [[String: Any]] = run.concerns.map { concern in
            var dict: [String: Any] = ["name": concern.name]
            switch concern.status {
            case .pending:
                dict["status"] = "pending"
            case .running(let taskId):
                dict["status"] = "running"
                dict["task_id"] = taskId
            case .completed(let taskId):
                dict["status"] = "completed"
                dict["task_id"] = taskId
            case .failed(let taskId, let message):
                dict["status"] = "failed"
                dict["task_id"] = taskId
                dict["error"] = message
            }
            if let summary = concern.summary {
                dict["summary"] = summary
            }
            return dict
        }
        let findings: [[String: Any]] = run.findings.map { f in
            var dict: [String: Any] = [
                "id": f.id,
                "file": f.file,
                "severity": f.severity.rawValue,
                "concern": f.concern,
                "title": f.title,
                "detail": f.detail,
                "fixable": f.fixable,
                "created_at": iso.string(from: f.createdAt)
            ]
            if let line = f.line {
                dict["line"] = line
            }
            if let suggestion = f.suggestion {
                dict["suggestion"] = suggestion
            }
            switch f.fixState {
            case .none:
                dict["fix_state"] = "none"
            case .queued:
                dict["fix_state"] = "queued"
            case .running(let taskId):
                dict["fix_state"] = "running"
                dict["fix_task_id"] = taskId
            case .applied:
                dict["fix_state"] = "applied"
            case .skipped(let reason):
                dict["fix_state"] = "skipped"
                dict["fix_state_reason"] = reason
            case .failed(let message):
                dict["fix_state"] = "failed"
                dict["fix_state_reason"] = message
            }
            return dict
        }
        let fixes: [[String: Any]] = run.fixes.map { fix in
            var dict: [String: Any] = [
                "task_id": fix.id,
                "file": fix.file,
                "finding_ids": fix.findingIds,
                "created_at": iso.string(from: fix.createdAt)
            ]
            if let outcome = fix.outcome {
                var outDict: [String: Any] = [
                    "applied": outcome.applied,
                    "skipped": outcome.skipped.map { ["finding_id": $0.findingId, "reason": $0.reason] }
                ]
                if let notes = outcome.notes {
                    outDict["notes"] = notes
                }
                dict["outcome"] = outDict
            }
            if let error = fix.error {
                dict["error"] = error
            }
            return dict
        }
        var result: [String: Any] = [
            "review_id": run.id,
            "created_at": iso.string(from: run.createdAt),
            "concerns": concerns,
            "findings": findings,
            "fixes": fixes
        ]
        if let stat = run.diffStat {
            result["diff_stat"] = stat
        }
        if let pid = run.parentSessionId {
            result["parent_session_id"] = pid
        }
        return result
    }

    @MainActor
    private static func submitFixResult(_ args: [String: Any]) throws -> String {
        guard let reviewId = CurrentMCPRequest.reviewId, !reviewId.isEmpty else {
            throw OdinMCPError.invalidArgument("submit_fix_result requires X-Review-Id header")
        }
        guard let taskId = CurrentMCPRequest.taskId, !taskId.isEmpty else {
            throw OdinMCPError.invalidArgument("submit_fix_result requires X-Task-Id header")
        }
        let appliedRaw = (args["applied"] as? [Any]) ?? []
        let applied: [String] = appliedRaw.compactMap { $0 as? String }
        let skippedRaw = (args["skipped"] as? [Any]) ?? []
        let skipped: [FixWorkerOutcome.Skip] = skippedRaw.compactMap { item in
            guard let dict = item as? [String: Any],
                  let reason = dict["reason"] as? String, !reason.isEmpty
            else { return nil }
            // Accept `finding_id` (the new shape) and `id` as a forgiving
            // alias — a worker that mis-keys to `id` shouldn't silently drop
            // the skip.
            let idCandidate = (dict["finding_id"] as? String) ?? (dict["id"] as? String)
            guard let findingId = idCandidate, !findingId.isEmpty else { return nil }
            return FixWorkerOutcome.Skip(findingId: findingId, reason: reason)
        }
        let notes = (args["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ReviewRunRegistry.shared.recordFixOutcome(
            reviewId: reviewId,
            taskId: taskId,
            outcome: FixWorkerOutcome(applied: applied, skipped: skipped, notes: notes)
        )
        return jsonString(["ok": true])
    }

    @MainActor
    private static func getTaskStatus(_ args: [String: Any]) throws -> String {
        guard let id = args["task_id"] as? String else {
            throw OdinMCPError.invalidArgument("task_id is required")
        }
        guard let runner = BackgroundTaskRegistry.shared.get(id) else {
            throw OdinMCPError.taskNotFound(id)
        }
        return jsonString(stateDict(runner: runner))
    }

    @MainActor
    private static func awaitTask(_ args: [String: Any]) async throws -> String {
        guard let id = args["task_id"] as? String else {
            throw OdinMCPError.invalidArgument("task_id is required")
        }
        guard let runner = BackgroundTaskRegistry.shared.get(id) else {
            throw OdinMCPError.taskNotFound(id)
        }
        let timeout = (args["timeout_seconds"] as? Double) ?? 300
        let final = await runner.awaitCompletion(timeout: timeout)
        var dict = stateDict(runner: runner)
        if final == nil {
            dict["timed_out"] = true
        }
        return jsonString(dict)
    }

    @MainActor
    private static func stateDict(runner: BackgroundClaudeRunner) -> [String: Any] {
        var dict: [String: Any] = [
            "task_id": runner.id,
            "cwd": runner.cwd,
            "created_at": ISO8601DateFormatter().string(from: runner.createdAt)
        ]
        switch runner.state {
        case .running:
            dict["status"] = "running"
        case .completed(let text):
            dict["status"] = "completed"
            dict["result"] = text
        case .failed(let msg):
            dict["status"] = "failed"
            dict["error"] = msg
        }
        return dict
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
#endif
