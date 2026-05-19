#if os(macOS)
import Foundation

/// Writes Odin's bundled skills to `~/.claude/skills/<name>/SKILL.md` on app
/// launch so any Claude Code session on the machine can discover them.
/// Always overwrites — bump the source string here and relaunch Odin to ship
/// an update.
enum OdinSkillInstaller {
    static func install() {
        let base = NSHomeDirectory() + "/.claude/skills"
        for skill in skills {
            let dir = base + "/" + skill.name
            let path = dir + "/SKILL.md"
            do {
                try FileManager.default.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true
                )
                try skill.body.write(
                    toFile: path,
                    atomically: true,
                    encoding: .utf8
                )
                NSLog("[OdinSkills] installed \(skill.name) → \(path)")
            } catch {
                NSLog("[OdinSkills] failed to install \(skill.name): \(error)")
            }
        }
    }

    private struct Skill {
        let name: String
        let body: String
    }

    private static let skills: [Skill] = [
        Skill(name: "odin-spawn", body: odinSpawn),
        Skill(name: "odin-orchestrate", body: odinOrchestrate),
        Skill(name: "odin-review", body: odinReview),
    ]

    private static let odinSpawn = #"""
    ---
    name: odin-spawn
    description: Spawn a headless Claude Code worker via Odin's local MCP for a scoped background task, then come back to it later — do not block waiting for the result. Use when a question needs file scans, large repo reads, exploratory grep, or any deep work that would bloat the current session's context. Triggers on phrases like "delegate", "in the background", "fire and forget", "spawn a worker", "use odin to".
    ---

    # Spawn a background Claude worker — fire and forget

    The Odin MCP exposes three tools backed by Odin's in-process server:

    - `mcp__odin__run_background_task(prompt, cwd?, model?)` — **returns immediately** with `{task_id, status: "running"}`. The worker keeps running. Pass `model` (e.g. `"claude-sonnet-4-6"`, `"claude-opus-4-7"`, `"claude-haiku-4-5"`) to pin a specific model; omit to use the host CLI default.
    - `mcp__odin__get_task_status(task_id)` — non-blocking snapshot. Call this when you want to peek.
    - `mcp__odin__await_task(task_id, timeout_seconds?)` — blocks the parent tool call until the worker exits. **Avoid unless you really need the answer in the same assistant turn.** Blocking here means you've turned a "background task" into a synchronous wait.

    Each call to `run_background_task` spawns a fresh `claude -p` subprocess with `--dangerously-skip-permissions`. It has no UI and lives only inside Odin.

    ## Recommended flow (pull pattern)

    1. Call `run_background_task` with a tight prompt and the right `cwd`. Capture the `task_id`.
    2. **Tell the user the task is running and return control.** Do not call `await_task`.
    3. Continue chatting. The user will steer the conversation.
    4. When the user asks, or when it makes sense to check (e.g. they say "is it done?"), call `get_task_status(task_id)`. If `status` is `"completed"`, use the `result`. If still `"running"`, say so.

    ### Bonus: auto-notification on next turn
    Odin also installs a `UserPromptSubmit` hook that injects a one-line notification into your context the next time the user sends a message, *if* a background task you spawned has completed since the last turn. So even without explicit polling, you'll learn about completion at the earliest natural moment — and can mention it to the user.

    ## When `await_task` IS appropriate

    Block only when:
    - The user's current request explicitly depends on the result ("tell me the count, then suggest next steps").
    - The work is genuinely short (a few seconds) and the result is small.

    Otherwise: spawn, tell the user, return.

    ## When to use this skill at all

    Spawn a worker when:
    - The task involves reading or scanning many files and you only need the *finding*, not the raw contents.
    - The task is repetitive (count, list, audit) and the result is a small value or summary.
    - The task can be expressed in one sentence and answered in a few words.

    Don't spawn a worker when:
    - The task is interactive — needs follow-up turns or user input.
    - The task is small enough to do inline.
    - The task requires writing to files outside the worker's brief.

    ## Example

    ```
    run_background_task(
      prompt: "Count the number of .swift files under the current directory recursively. Reply with just the number, nothing else.",
      cwd: "/Users/me/projects/odin--background/Odin"
    )
    → { "task_id": "t-a1b2c3d4", "status": "running", "cwd": "..." }

    # Tell the user: "Started t-a1b2c3d4 — I'll let you know when it finishes."
    # Continue chatting. Either the auto-notification surfaces the result on a future
    # turn, or you can call get_task_status when asked.

    get_task_status(task_id: "t-a1b2c3d4")
    → { "task_id": "t-a1b2c3d4", "status": "completed", "result": "47" }
    ```

    ## Gotchas

    - Workers run with `--dangerously-skip-permissions`. Scope the prompt so the worker can't do damage.
    - Workers don't share your context. Restate every fact they need in the prompt.
    - On failure, `status` becomes `"failed"` and the error is in `error`. Read it before retrying.
    """#

    private static let odinOrchestrate = #"""
    ---
    name: odin-orchestrate
    description: Fan out parallel background Claude workers via Odin's local MCP and join the results. Use when multiple independent investigations can run concurrently — auditing several modules at once, asking the same question across multiple directories, or any N-way map-then-synthesize problem. Triggers on phrases like "in parallel", "fan out", "for each ... run a worker", "multiple background tasks", "orchestrate".
    ---

    # Orchestrate parallel background workers

    When N independent tasks can each be answered by a one-shot Claude worker, spawn them all, then either await them all (if you need the joined result this turn) or check status on a future turn (preferred — see odin-spawn for the fire-and-forget pattern).

    ## When to use

    - N>1 independent investigations of similar shape ("look at each of these N folders and report X").
    - Cross-cutting audits where each worker reports one small structured fact.
    - Bulk file-shape work where each worker's output is tiny.

    Don't orchestrate when:
    - Tasks have dependencies — chain them sequentially instead.
    - The combined work fits in one worker — just spawn one.

    ## How to use

    1. Build the list of (label, prompt, cwd) tuples up front.
    2. Issue all `run_background_task` calls in a single assistant turn as parallel tool calls.
    3. Collect the returned `task_id`s.
    4. **Default: return control to the user.** Mention you've fanned out N workers. Check status on a later turn — or let the auto-notification hook surface results when they're ready.
    5. **Only if the user needs the joined result right now:** issue all `await_task` calls in a single assistant turn as parallel tool calls, then synthesize.

    ## Example

    ```
    # Step 2: parallel spawns
    run_background_task(prompt: "Count Swift files. Reply with just the number.", cwd: "/path/A") → t-1
    run_background_task(prompt: "Count Swift files. Reply with just the number.", cwd: "/path/B") → t-2
    run_background_task(prompt: "Count Swift files. Reply with just the number.", cwd: "/path/C") → t-3

    # Default: tell the user "fanned out across A/B/C, will report when ready"

    # Or, if needed this turn: parallel awaits
    await_task(t-1) → "12"
    await_task(t-2) → "47"
    await_task(t-3) → "9"
    # Synthesize: "A=12, B=47, C=9 — 68 Swift files total."
    ```

    ## Gotchas

    - Each worker is a full Claude Code session. Twenty workers spend twenty contexts — cap fan-out at 3-5.
    - Workers don't see each other. If B needs A's output, await A first and pass the value into B's prompt.
    - If one worker fails, the rest still complete. Inspect each result before synthesizing.
    """#

    private static let odinReview = #"""
    ---
    name: odin-review
    description: Fan out parallel background Claude workers via Odin's local MCP to review the current branch's changes, then optionally spawn fix workers to apply corrections. Triggers ONLY when the user explicitly invokes Odin — phrases like "odin review", "use odin to review", "odin audit", "review with odin", "have odin look at this branch". Without an explicit "odin" mention, do NOT invoke this skill — use the inline /review path or review in the current session instead.
    ---

    # Structured branch review via parallel background workers

    Reviewing a diff is naturally fan-out shaped: several independent passes (correctness, security, tests, style) each produce a small list of findings against the same input. Spawn one worker per concern, dedupe, present — then, if the user wants, spawn fix workers to apply the corrections.

    **Two phases, kept distinct:**
    1. **Review phase** — workers return JSON findings only. No file writes. Read-only by prompt contract.
    2. **Fix phase** — separate workers, each scoped to a single file, explicitly authorized to edit. User opts in after seeing findings.

    All workers run on **Sonnet 4.6** (`claude-sonnet-4-6`). Pass `model: "claude-sonnet-4-6"` on every `run_background_task` call this skill makes — don't fall back to the host CLI default.

    ## When to use

    - User says "odin" and asks for a review, audit, or second opinion on the branch.
    - Pre-PR audit before `/ship`, `git push`, or merging — explicitly via Odin.
    - User wants a thorough review that doesn't burn context in the current Claude tab.

    Do NOT use when:
    - The user asks for a review without mentioning Odin — use `/review` or review inline.
    - The change is one or two lines — review inline.
    - The user wants a discussion, not findings — interactive review beats fan-out.

    ## Phase 1 — Review (fan-out, read-only)

    1. **Capture the diff.** Run `git diff main...HEAD` (or scoped variant: `--staged`, a specific PR head, a single path). Confirm it's non-empty. If it's large, also run `git diff --stat` so the user knows what's being reviewed.
    2. **Pick the concern set.** Default: correctness, security, tests, style. Add `performance` for hot-path code; add `api-compat` for public-API or schema changes. **Cap at 5.**
    3. **Fan out in one turn.** Issue all `run_background_task` calls as parallel tool calls. Each worker gets the same diff, one concern, the read-only finding contract, and `model: "claude-sonnet-4-6"`.
    4. **Return control to the user.** Tell them which concerns are running. The auto-notification hook will surface completions.
    5. **Collate when results land.** Parse JSON, dedupe by `file:line + title` (keep the higher-severity hit and merge concerns), sort by severity, present compactly.

    ### Review-worker prompt template

    ```
    You are reviewing a diff for {concern}. You are a READ-ONLY reviewer.

    DO NOT edit files. DO NOT run write commands. Your only job is to report findings.

    Below is the full diff:

    [paste git diff output]

    Find issues relevant ONLY to {concern}. Output a JSON array of findings:
    [
      {
        "file": "path/to/file.swift",
        "line": 42,
        "severity": "blocker | major | minor | nit",
        "concern": "{concern}",
        "title": "one-line summary",
        "detail": "one paragraph: what's wrong and why",
        "suggestion": "concrete change, or null",
        "fixable": true
      }
    ]

    Rules:
    - Use line numbers from the new file (post-change).
    - Empty array if nothing found — do not pad.
    - "fixable": true only if a single-file edit clearly resolves it. Architectural issues, anything needing new files, anything needing human judgement: false.
    - {concern}-specific guidance: [paste relevant block from per-concern notes below]

    Reply with the JSON array only, no prose.
    ```

    ### Severity rubric

    - **blocker** — ship and something breaks (crash, data loss, security hole, broken contract).
    - **major** — wrong in a way reviewers would block on (incorrect logic in a non-fatal path, missing test for new behavior, secret in a log).
    - **minor** — real issue, not blocking.
    - **nit** — style/taste. Only the `style` worker reports these.

    ### Per-concern guidance

    - **correctness** — Wrong logic, off-by-one, nil/unwrap traps, race conditions, error swallowing, broken invariants.
    - **security** — Injection, auth bypass, secret leakage, unsafe deserialization, path traversal, missing host-key/cert verification.
    - **tests** — New behavior without tests, weakened assertions, tests that pass without exercising the change, missing edge cases. `fixable: false` if the fix needs a new test file.
    - **style** — Naming, idiom, dead code, complexity, comments that lie or restate the code.
    - **performance** — Hot-path allocations, N+1, sync I/O on main, missing caching when there's an obvious key.
    - **api-compat** — Breaking changes to public types, removed/renamed exports, schema fields, JSON shape. Almost always `fixable: false` — needs human call.

    ## Phase 2 — Fix (opt-in, write-authorized)

    After presenting findings, ask the user what to fix. Common patterns:
    - "fix the blockers" → fix workers for findings where `severity == "blocker" && fixable == true`.
    - "fix all auto-fixable" → fix workers for any `fixable: true`.
    - "fix the security ones" → filter by concern.
    - "skip" → done.

    ### How to spawn fix workers

    Group findings by **file**, not by concern — one fix worker per file. This avoids edit conflicts and lets each worker see the full local context. Each fix worker:

    1. Receives the JSON findings it's responsible for (just the ones for its file).
    2. Is told it MAY edit that one file.
    3. Is told it may NOT touch any other path.

    ### Fix-worker prompt template

    ```
    You are applying review fixes to a single file. You ARE authorized to edit this file.

    File: {path}
    You may edit ONLY this file. Do not touch any other path.

    Findings to address:
    [paste filtered JSON findings for this file]

    For each finding:
    1. Open the file and locate the issue.
    2. Apply the smallest change that resolves it. If "suggestion" is concrete, prefer it.
    3. Do not refactor unrelated code. Do not add tests unless a finding explicitly asks.
    4. If a finding is wrong on inspection (false positive), skip it and note why.

    When done, output a JSON object:
    {
      "file": "{path}",
      "applied": [<finding titles you fixed>],
      "skipped": [{"title": "...", "reason": "..."}],
      "notes": "anything the user should know, or null"
    }

    Reply with the JSON object only, no prose.
    ```

    Pass `model: "claude-sonnet-4-6"` here too.

    ### After fix workers complete

    1. Collect the per-file results (parse JSON; if a worker returned non-JSON, surface it as a fix failure for that file — don't try to fix it inline).
    2. Run `git diff` so the user can see what changed.
    3. Report: N findings applied across M files, K skipped (with reasons).
    4. **Do not commit.** Leave the working tree dirty so the user can inspect, amend, and commit themselves.

    ## Example flow

    ```
    User: "odin, review my branch"

    # Phase 1: capture
    git diff main...HEAD                                         (1.2k lines, 18 files)
    git diff --stat                                              (for the user)

    # Phase 1: fan out (one turn, parallel tool calls)
    run_background_task(prompt: "<correctness template + diff>", cwd: <repo>, model: "claude-sonnet-4-6") → t-1
    run_background_task(prompt: "<security template + diff>",   cwd: <repo>, model: "claude-sonnet-4-6") → t-2
    run_background_task(prompt: "<tests template + diff>",      cwd: <repo>, model: "claude-sonnet-4-6") → t-3
    run_background_task(prompt: "<style template + diff>",      cwd: <repo>, model: "claude-sonnet-4-6") → t-4

    # Tell user: "Fanned out 4 reviewers (correctness, security, tests, style) on Sonnet 4.6.
    #              I'll report back when they're in."

    # When complete: collate + present
    # blocker x1, major x3, minor x2, nits suppressed unless asked
    # Ask: "Want me to fix the auto-fixable ones?"

    User: "fix the blockers"

    # Phase 2: 1 blocker, scoped to FileA.swift
    run_background_task(prompt: "<fix template for FileA.swift + filtered findings>", cwd: <repo>, model: "claude-sonnet-4-6") → t-5

    # When complete: git diff, report applied/skipped, leave tree dirty for user.
    ```

    ## Gotchas

    - **Trigger requires "odin".** If the user said "review my changes" without naming Odin, do not invoke this skill — use the inline review path instead.
    - **Always pass `model: "claude-sonnet-4-6"`.** Don't fall through to the host CLI default — this skill is designed around Sonnet's behavior.
    - **Workers don't see CLAUDE.md.** If review needs project conventions, paste the relevant section into the prompt.
    - **Diff size.** If >2k lines, narrow scope or split by directory and run one fan-out per directory.
    - **Workers run with `--dangerously-skip-permissions`.** Review workers MUST be told not to edit (the prompt does this). Fix workers ARE told they may edit only one named file. Don't loosen either prompt.
    - **Don't commit fix-worker output.** Leave it for the user to review with `git diff` first.
    - **One worker per concern, not per file (review phase).** Cross-file issues get lost when reviewers only see one file.
    - **One worker per file, not per finding (fix phase).** Multiple findings against the same file should go to the same fix worker to avoid edit conflicts.
    """#
}
#endif
