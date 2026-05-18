#if os(macOS)
import Foundation

/// Writes Odin's bundled skills to `~/.claude/skills/<name>/SKILL.md` on app
/// launch so any Claude Code session on the machine can discover them. Only
/// writes when the destination file is missing — user edits are preserved.
enum OdinSkillInstaller {
    static func install() {
        let base = NSHomeDirectory() + "/.claude/skills"
        for skill in skills {
            let dir = base + "/" + skill.name
            let path = dir + "/SKILL.md"
            if FileManager.default.fileExists(atPath: path) { continue }
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
    description: Spawn a single headless Claude Code worker via Odin's local MCP to perform a scoped task in the background. Use when a question needs file scans, large repo reads, exploratory grep, or any deep work that would bloat the current session's context. Triggers on phrases like "delegate", "in the background", "spawn a worker", "fork a session", "use odin to".
    ---

    # Spawn a background Claude worker

    The Odin MCP exposes three tools backed by Odin's in-process server:

    - `mcp__odin__run_background_task(prompt, cwd?)` → returns `{task_id, status: "running", cwd}`
    - `mcp__odin__get_task_status(task_id)` → non-blocking status snapshot
    - `mcp__odin__await_task(task_id, timeout_seconds?)` → blocks until done

    Each call to `run_background_task` spawns a fresh `claude -p` subprocess with `--dangerously-skip-permissions`. It has no UI and lives only inside Odin.

    ## When to use

    Spawn a worker when:
    - The task involves reading or scanning many files and you only need the *finding*, not the raw contents.
    - The task is repetitive (count, list, audit) and the result is a small value or summary.
    - The task can be expressed in one sentence and answered in a few words or a small JSON object.

    Don't spawn a worker when:
    - The task is interactive — needs follow-up turns or user input.
    - The task is small enough to do inline.
    - The task requires writing to files outside the worker's brief.

    ## How to use

    1. Write a tight prompt that names the expected output format. Workers default to verbose; force terseness.
    2. Call `run_background_task` with `prompt` and `cwd`. Capture the `task_id`.
    3. Call `await_task` with that `task_id`. The worker's final stdout text comes back as `result`.

    ## Example

    ```
    run_background_task(
      prompt: "Count the number of Swift files under the current directory recursively. Reply with just the number, nothing else.",
      cwd: "/Users/me/projects/odin--background/Odin"
    )
    → { "task_id": "t-a1b2c3d4", "status": "running", "cwd": "..." }

    await_task(task_id: "t-a1b2c3d4")
    → { "task_id": "t-a1b2c3d4", "status": "completed", "result": "47" }
    ```

    ## Gotchas

    - Workers run with `--dangerously-skip-permissions`. Scope the prompt so the worker can't do damage.
    - Workers don't share your context. Restate every fact they need in the prompt.
    - `await_task` defaults to a 300-second timeout. Pass `timeout_seconds` for larger jobs.
    - On failure, `status` becomes `"failed"` and the error is in `error`. Read it before retrying.
    """#

    private static let odinOrchestrate = #"""
    ---
    name: odin-orchestrate
    description: Fan out parallel background Claude workers via Odin's local MCP and join the results. Use when multiple independent investigations can run concurrently — auditing several modules at once, asking the same question across multiple directories, or any N-way map-then-synthesize problem. Triggers on phrases like "in parallel", "fan out", "for each ... run a worker", "multiple background tasks", "orchestrate".
    ---

    # Orchestrate parallel background workers

    When N independent tasks can each be answered by a one-shot Claude worker, spawn them all, await them all, then synthesize the joined results in this session.

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
    4. Issue all `await_task` calls in a single assistant turn as parallel tool calls.
    5. Synthesize the joined results into a single answer for the user.

    ## Example

    ```
    # Step 2: parallel spawns
    run_background_task(prompt: "Count Swift files. Reply with just the number.", cwd: "/path/A") → t-1
    run_background_task(prompt: "Count Swift files. Reply with just the number.", cwd: "/path/B") → t-2
    run_background_task(prompt: "Count Swift files. Reply with just the number.", cwd: "/path/C") → t-3

    # Step 4: parallel awaits
    await_task(t-1) → "12"
    await_task(t-2) → "47"
    await_task(t-3) → "9"

    # Step 5: synthesize for the user
    "A=12, B=47, C=9 — 68 Swift files total."
    ```

    ## Gotchas

    - Each worker is a full Claude Code session. Twenty workers spend twenty contexts — cap fan-out at 3-5.
    - Workers don't see each other. If B needs A's output, await A first and pass the value into B's prompt.
    - If one worker fails, the rest still complete. Inspect each `await_task` result before synthesizing.
    """#
}
#endif
