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
    ]

    private static let odinSpawn = #"""
    ---
    name: odin-spawn
    description: Spawn a headless Claude Code worker via Odin's local MCP for a scoped background task, then come back to it later — do not block waiting for the result. Use when a question needs file scans, large repo reads, exploratory grep, or any deep work that would bloat the current session's context. Triggers on phrases like "delegate", "in the background", "fire and forget", "spawn a worker", "use odin to".
    ---

    # Spawn a background Claude worker — fire and forget

    The Odin MCP exposes three tools backed by Odin's in-process server:

    - `mcp__odin__run_background_task(prompt, cwd?)` — **returns immediately** with `{task_id, status: "running"}`. The worker keeps running.
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
}
#endif
