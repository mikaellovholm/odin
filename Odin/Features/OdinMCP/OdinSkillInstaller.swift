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

    The Odin MCP exposes these tools backed by Odin's in-process server:

    - `mcp__odin__run_background_task(prompt, cwd?, model?)` — **returns immediately** with `{task_id, status: "running"}`. The worker keeps running. Pass `model` (e.g. `"claude-sonnet-4-6"`, `"claude-opus-4-7"`, `"claude-haiku-4-5"`) to pin a specific model; omit to use the host CLI default.
    - `mcp__odin__get_task_status(task_id)` — non-blocking snapshot. Call this when you want to peek.
    - `mcp__odin__await_task(task_id, timeout_seconds?)` — blocks the parent tool call until the worker exits. **Avoid unless you really need the answer in the same assistant turn.** Blocking here means you've turned a "background task" into a synchronous wait.
    - `mcp__odin__stop_task(task_id)` — send SIGTERM to a single worker. Use when the user asks to cancel a specific task. Returns immediately; the worker may take a moment to actually exit. Final state surfaces as `failed` with `"cancelled by user"`.

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
    description: Fan out parallel background Claude workers via Odin's local MCP to review the current branch's changes. Findings stream live into Odin's review pane (⇧⌘R) and the user opts into fixes from there. Triggers ONLY when the user explicitly invokes Odin — phrases like "odin review", "use odin to review", "odin audit", "review with odin", "have odin look at this branch". Without an explicit "odin" mention, do NOT invoke this skill — use the inline /review path or review in the current session instead.
    ---

    # Structured branch review — workers stream findings into Odin's review pane

    Reviewing a diff is naturally fan-out shaped: several independent passes (correctness, security, tests, style) each produce a small list of findings against the same input. This skill spawns one Odin-backed worker per concern. Each worker calls `mcp__odin__submit_finding` for every issue it finds — Odin renders the findings live in the review pane (⇧⌘R) as they arrive. You do not collect, parse, or present findings yourself; the panel is the surface.

    **Fix workers are panel-driven, not your job.** After Phase 1 is dispatched, tell the user the findings will appear in the review pane and direct them there. They click Fix buttons to apply individual or bulk fixes (the panel spawns fix workers internally). Do not call `submit_fix_result` or attempt to dispatch fix workers from the skill — that's reserved for Odin's panel.

    All workers run on **Sonnet 4.6** (`claude-sonnet-4-6`). Pass `model: "claude-sonnet-4-6"` on every `run_background_task` call this skill makes — don't fall back to the host CLI default.

    ## When to use

    - User says "odin" and asks for a review, audit, or second opinion on the branch.
    - Pre-PR audit before `/ship`, `git push`, or merging — explicitly via Odin.
    - User wants a thorough review that doesn't burn context in the current Claude tab.

    Do NOT use when:
    - The user asks for a review without mentioning Odin — use `/review` or review inline.
    - The change is one or two lines — review inline.
    - The user wants a discussion, not findings — interactive review beats fan-out.

    ## Procedure

    Keep the orchestrator's output **tiny**. Each worker fetches the diff itself, so you must NEVER paste the diff into a `run_background_task` prompt — that forces you to regenerate the full diff once per concern (4× for the default set) before any worker even starts. Workers run `git diff` in their own `cwd` instead.

    1. **Pick the diff scope.** Decide the base ref. Common choices: `main...HEAD` (branch review), `HEAD` (uncommitted), `--staged`, `<sha>..HEAD`. You only need to know which to instruct the workers to use — do NOT capture the diff text in your own context.
    2. **Get a one-line stat for the panel header.** Run exactly: `git diff <scope> --stat | tail -1`. Capture only that one line, not the full diff. Pass it as `diff_stat`.
    3. **Pick the concern set.** Default: correctness, security, tests, style. Add `performance` for hot-path code; add `api-compat` for public-API or schema changes. **Cap at 5.**
    4. **Open the review run.** Call `mcp__odin__start_review_run(concerns: [...], diff_stat: "...")` and capture the returned `review_id`.
    5. **Fan out in one turn.** Issue all `run_background_task` calls as parallel tool calls. Each prompt is short — the template below, with `{concern}`, `{diff_scope}`, and the concern-specific guidance block filled in. `cwd` must be the worktree root. Pass `review_id`, `concern`, and `model: "claude-sonnet-4-6"`. The worker's `.mcp.json` is wired automatically by Odin — workers get `mcp__odin__submit_finding` and `mcp__odin__complete_review_worker` access scoped to this review.
    6. **Tell the user findings will appear in the review pane (⇧⌘R) live, and that they can click Fix buttons there for any auto-fixable issue.** Return control. Do NOT collate findings yourself. Do NOT summarize them. Do NOT call `get_task_status` or `await_task`. The panel is the surface.

    ### Review-worker prompt template

    Keep this short. The diff is fetched by the worker, not pasted by you.

    ```
    You are reviewing a git diff for {concern}. You are a READ-ONLY reviewer.

    DO NOT edit files. DO NOT run write commands. Your only job is to report findings.

    Step 1: Run `git diff {diff_scope}` in the current directory to see the changes you are reviewing. If you need file-level context for a hunk, you may also `cat` or `head` the relevant file at the post-change state.

    Step 2: For every issue you find relevant to {concern}, call mcp__odin__submit_finding with:
      - file: path/to/file.swift (relative to the worktree root)
      - line: integer (1-based, post-change file). Omit for file-level issues.
      - severity: "blocker" | "major" | "minor" | "nit"
      - title: one-line summary
      - detail: one paragraph — what's wrong and why
      - suggestion: concrete change as a string, or omit if no single edit clearly resolves it
      - fixable: true only if a single-file edit clearly resolves it. Architectural issues, anything needing new files, anything needing human judgement: false.

    Submit findings one at a time. Do NOT batch them or output a JSON array.

    Step 3: After you've submitted every finding (or if you found nothing), call mcp__odin__complete_review_worker with an optional one-line summary of what you checked.

    Step 4: Reply with just the string "DONE".

    {concern}-specific guidance: [paste relevant block from per-concern notes below]
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

    ## Reading findings back

    The panel shows findings live. You usually shouldn't talk about them at all. But if the user asks a specific question — *"explain the security blocker"*, *"what did the style reviewer find"*, *"is the api-compat one fixable"* — call `mcp__odin__get_review_run` (no args; it uses your tab's `X-Session-Id` to find the latest run). The response carries every concern's status, every finding (id, file, line, severity, concern, title, detail, suggestion, fixable, fix_state), and every fix worker's outcome. Answer the user's question from that data; don't dump the whole JSON back at them.

    Do NOT call `get_review_run` proactively after dispatch — the panel is the surface and the user is already looking at it. Only fetch when the user asks something you can't answer without it.

    ## Cancelling a review

    If the user asks to stop the background review ("cancel", "stop the review", "kill the workers"), call `mcp__odin__stop_review_run` with no arguments — it defaults to the latest run for this tab and signals every in-flight reviewer and fix worker. Report the `stopped_count` back to the user. Cancelled workers surface in the panel as failed with "cancelled by user".

    ## Fixes are panel-driven

    Do NOT spawn fix workers from this skill. After Phase 1 dispatch, point the user at the review pane (⇧⌘R) and let them click `Fix` on individual findings or `Fix all blockers` / `Fix all auto-fixable` in bulk. Odin spawns the fix workers internally, scopes each one to a single file, gives it `mcp__odin__submit_fix_result` access, and surfaces the applied/skipped state per finding in the panel.

    If the user explicitly asks you (the chat-side Claude) to apply a specific fix, just edit the file directly with your normal tools — don't try to mimic the panel's fix-worker flow.

    ## Example flow

    ```
    User: "odin, review my branch"

    # Stat only — do NOT capture the full diff into your own context
    git diff main...HEAD --stat | tail -1                        "18 files changed, 1242 insertions(+), 187 deletions(-)"

    # Open the run
    start_review_run(
      concerns: ["correctness", "security", "tests", "style"],
      diff_stat: "18 files changed, 1242 insertions(+), 187 deletions(-)"
    ) → { "review_id": "r-abcd1234", ... }

    # Fan out (one turn, parallel tool calls). Each prompt is small — the
    # template with {concern} and diff_scope="main...HEAD" filled in.
    run_background_task(prompt: "<short correctness template>", cwd: <repo>, model: "claude-sonnet-4-6", review_id: "r-abcd1234", concern: "correctness") → t-1
    run_background_task(prompt: "<short security template>",    cwd: <repo>, model: "claude-sonnet-4-6", review_id: "r-abcd1234", concern: "security")    → t-2
    run_background_task(prompt: "<short tests template>",       cwd: <repo>, model: "claude-sonnet-4-6", review_id: "r-abcd1234", concern: "tests")       → t-3
    run_background_task(prompt: "<short style template>",       cwd: <repo>, model: "claude-sonnet-4-6", review_id: "r-abcd1234", concern: "style")       → t-4

    # Tell user: "Fanned out 4 reviewers (correctness, security, tests, style) on Sonnet 4.6.
    #              Findings will appear in the review pane (⇧⌘R) as they land.
    #              Click Fix on any auto-fixable finding to apply it."
    # Return control. Do not poll or summarize.
    ```

    ## Gotchas

    - **NEVER paste the diff into worker prompts.** Each `run_background_task` prompt must be tiny — the template + concern guidance + diff scope ref only. Workers fetch the diff with `git diff` in their `cwd`. Pasting the diff into 4 prompts means you regenerate the full diff 4× before any worker spawns, and the user sees the orchestrator "doodling" for minutes instead of returning immediately.
    - **Trigger requires "odin".** If the user said "review my changes" without naming Odin, do not invoke this skill — use the inline review path instead.
    - **Always pass `model: "claude-sonnet-4-6"`.** Don't fall through to the host CLI default — this skill is designed around Sonnet's behavior.
    - **Always call `start_review_run` first.** Without a `review_id`, workers can't call `submit_finding` and findings won't appear in the panel.
    - **Workers don't see CLAUDE.md.** If review needs project conventions, paste the relevant section into the prompt.
    - **Diff size.** If >2k lines, narrow scope or split by directory and run one fan-out per directory.
    - **Workers run with `--dangerously-skip-permissions` AND have MCP access scoped to this review.** The prompt forbids file edits — don't loosen it. The MCP scoping means a reviewer can only submit findings to its own review run, not anyone else's.
    - **One worker per concern.** Cross-file issues get lost when reviewers only see one file.
    - **Don't collate or present findings in chat.** The panel does that. Repeating findings in chat is noise.
    """#
}
#endif
