# Fix plan

Generated from the deep review. Ordered by priority: security first, then real bugs, then docs/UX, then smells/cleanup. Each item describes the change and the file(s) it touches.

---

## P0 — Security

### 1. Add a per-launch auth token to OdinMCP
**Problem:** Loopback-only is not a trust boundary — any user-level process can call `POST /mcp` and spawn `claude -p … --dangerously-skip-permissions`.

**Change:**
- In `OdinMCPServer`, generate a random 32-byte hex token at server start; expose via a new `authToken` property.
- In `OdinMCPServer.dispatch`, require header `X-Odin-Auth: <token>` and compare in constant time (`memcmp`-based helper on equal-length `Data`).
- In `LocalTerminalViewModel.writeMCPConfig`, inject `headers: { "X-Odin-Auth": "<token>", "X-Session-Id": sessionId }` into the `.mcp.json` so the child Claude carries it on every call.
- Reject unauthenticated requests with `401` and `Connection: close`. No body.

**Files:** `Odin/Features/OdinMCP/OdinMCPServer.swift`, `Odin/Features/Claude/LocalTerminalViewModel.swift`.

### 2. Sanitize background-worker output before re-injection
**Problem:** Worker stdout is wrapped in `<odin-background-notification>` and fed back into the parent's next turn, letting a worker emit the closing tag and inject instructions.

**Change:**
- In `BackgroundClaudeRunner.appendPendingNotification`, replace any occurrence of `</odin-background-notification>` (case-insensitive) in `stdoutBuffer`, `stderrBuffer`, and the truncated prompt prefix with a safe placeholder (e.g. `</odin-background-notification[stripped]>`).
- Same for the opening tag, to keep nesting impossible.
- Cap injected stdout at e.g. 8 KB and append a `[truncated]` marker.

**Files:** `Odin/Features/OdinMCP/BackgroundClaudeRunner.swift`.

### 3. Resolve `claude` binary without sourcing user rc files
**Problem:** `ClaudePath.resolve` and `LocalTerminalViewModel.startClaude` both go through `zsh -ilc`, trusting `~/.zshrc` / `~/.zprofile`.

**Change:**
- In `ClaudePath.resolve`, drop the `zsh -ilc 'which claude'` fallback. Add `~/.claude/local/claude` (the official user install path) to the explicit search list and stop there.
- In `LocalTerminalViewModel.startClaude`, spawn the resolved absolute path directly via `LocalProcess.startProcess(executable:args:environment:execName:)` instead of going through `/bin/zsh -ilc`. Set `PATH` explicitly to a known-good default (`/usr/local/bin:/opt/homebrew/bin:~/.local/bin:/usr/bin:/bin`).
- If neither lookup finds `claude`, surface a setup-required state with a single line: "Install Claude Code CLI; expected at /opt/homebrew/bin/claude or ~/.claude/local/claude".

**Files:** `Odin/Features/Claude/ClaudePath.swift`, `Odin/Features/Claude/LocalTerminalViewModel.swift`.

### 4. Cloud Function hardening
**Change:**
- `cloud-functions/claude-dev-starter/index.js`:
  - Replace `req.headers["x-api-key"] !== apiKey` with `crypto.timingSafeEqual` on `Buffer.from(...)` of equal length; bail on length mismatch first.
  - Fail closed if `process.env.API_KEY` is unset — return `500 {error:"server misconfigured"}` and log.
  - In the 500 path, do not echo `err.message`; log it server-side and return `{error:"internal_error"}`.

**Files:** `cloud-functions/claude-dev-starter/index.js`.

### 5. Tighten worktree name validation
**Problem:** Validator misses `; & ` ` $ ( ) | < > ' " \n` and `.`-leading names.

**Change:**
- In `WorktreeService.validateName`, add a single allow-list regex (`^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$`) and explicitly reject `..`, leading `-` (already covered), and leading `.`. Names go through `Process arguments` so this is robustness, not injection — but fail-fast beats unfriendly git errors.

**Files:** `Odin/Features/Claude/WorktreeService.swift`.

---

## P1 — Bugs that fire in normal use

### 6. Terminate child processes on app quit
**Change:**
- Add `OdinAppLifecycle` static helper called from `OdinApp.body`'s root view `.onChange(of: scenePhase) { _, new in if new == .background { ... } }` and `NSApplication.willTerminateNotification` observer (macOS).
- The handler iterates `ClaudeSessionStore.shared.sessions`, calls `viewModel.terminate()` and `shellViewModel.terminate()` on each.
- Add `OdinMCPServer.stop()` (cancel listener, set `listener = nil`) and call it from the same teardown.
- Also delete `~/.claude/odin-pending/*` and `~/.claude/odin-status/*` for sessions we own on quit.

**Files:** `Odin/OdinApp.swift`, `Odin/Features/Claude/ClaudeSessionStore.swift`, `Odin/Features/OdinMCP/OdinMCPServer.swift`.

### 7. Stream `BackgroundClaudeRunner` pipes instead of buffering to deadlock
**Problem:** 64 KB pipe buffer fills, child blocks in `write(2)`, `terminationHandler` never fires.

**Change:**
- Replace `readDataToEndOfFile()`-in-termination with `pipe.fileHandleForReading.readabilityHandler = { … }` that appends to `stdoutBuffer` as data arrives.
- Clear the handler in `terminationHandler`; do one final drain.
- Cap retained buffer at e.g. 256 KB with a "[output truncated]" suffix to bound memory.

**Files:** `Odin/Features/OdinMCP/BackgroundClaudeRunner.swift`.

### 8. Fix `BackgroundTaskRegistry` cap
**Change:**
- In `pruneIfNeeded`, separate the cap check: if `tasks.count > maxRetained` and `completed.isEmpty`, log a warning (or NSLog) once and exit — running tasks can't be evicted, that's correct. Bump `maxRetained` to e.g. 200 to absorb burst usage.
- Add a small "running task count" return on `create` so callers can detect saturation.

**Files:** `Odin/Features/OdinMCP/BackgroundTaskRegistry.swift`.

### 9. Gate `DiffViewModel.refresh` results on the refresh generation
**Change:**
- In `refresh()`, capture `let gen = refreshGeneration` before any await and after each `await` check `guard gen == refreshGeneration else { return }`. Apply to: file-list parse, per-file `loadDiff` await, the `isLoading = false` assignment.
- Same audit pass for `ProjectPanelViewModel.reload`.

**Files:** `Odin/Features/Claude/Diff/DiffViewModel.swift`, `Odin/Features/Claude/Project/ProjectPanelViewModel.swift`.

### 10. Bump `Note.updatedAt` correctly across re-edits
**Change:**
- In `NoteDetailView`, key `didBumpUpdatedAt` to `note.id` via `@State` + `.onChange(of: note.id) { didBumpUpdatedAt = false }`. Alternatively reset on `.onDisappear`.

**Files:** `Odin/Features/Notes/NoteDetailView.swift`.

### 11. Resolve `⇧⌘M` collision
**Change:**
- Rename `NoteDetailView`'s preview-toggle to `⌥⌘M` (or `⇧⌘P` — but ⇧⌘P is project pane).
- Pick `⌥⌘M` for the Notes preview toggle. Keep `⇧⌘M` on `FileViewerView` (the Claude tab one is more discoverable inside that surface).
- Update CLAUDE.md.

**Files:** `Odin/Features/Notes/NoteDetailView.swift`, `CLAUDE.md`.

### 12. Make `statusFileSource` resilient to atomic-rename writes
**Change:**
- In `LocalTerminalViewModel.startStatusWatcher`, when the watcher fires `.delete` or `.rename`, cancel the existing source and re-open the file (pre-creating it again) on the next runloop tick. Bail after N consecutive re-open attempts within a short window.

**Files:** `Odin/Features/Claude/LocalTerminalViewModel.swift`.

---

## P2 — Docs drift (CLAUDE.md)

### 13. Update CLAUDE.md to match code
**Change:** Single docs pass covering:
- Tab enum is `AppTab.remote`, not `.terminal`. Update every reference.
- Document the single context-sensitive `⌘N` for new-item (creates Claude session / note / todo based on `selectedTab`). Remove all mentions of `⇧⌘N` (New Note) and `⌥⌘T` (New Todo) — those shortcuts don't exist and won't be added.
- Permission-vs-input dots are both green now (single-dot unification, commit `4a8cd32`). Remove cyan claims.
- Add `MarkdownUI` to dependencies section.
- Document `Features/About/`, `AboutWindowController`, in-tabbar info button.
- Document `RightPaneMode` and deep-link plumbing from review pane → project panel.
- Document `pendingFocusLine`, `clearSelection` on the project panel.
- Document `⇧⌘M` preview toggles (per #11 above).

**Files:** `CLAUDE.md`.

---

## P3 — Error surfacing

### 14. Surface MCP / installer failures in the UI
**Change:**
- Add `@Observable` `OdinDiagnostics.shared` with `mcpStatus: enum { ok, failed(String) }`, `hooksStatus`, `skillsStatus`.
- `OdinApp.init`'s setup `Task` writes to it on failure.
- Add a small inline banner above the Claude sidebar header when any status != ok; click reveals the message.
- Bonus: a "Diagnostics" tab in `SettingsView` showing MCP port, installed hook paths, and status files.

**Files:** `Odin/OdinApp.swift`, `Odin/Features/Claude/ClaudeSessionListView.swift`, `Odin/Features/Settings/SettingsView.swift`, new `Odin/Features/Diagnostics/OdinDiagnostics.swift`.

### 15. Special-case Cloud Function 429 in terminal error UI
**Change:**
- `TerminalContainerView.stateOverlay` `.error` case: if the underlying error is `VMStarterError.rateLimited(retryAfter:)`, render "Cloud Function rate-limited. Retry in <N>s." and disable the Retry button until the countdown elapses.

**Files:** `Odin/Features/Terminal/TerminalContainerView.swift`.

### 16. Stop swallowing `NotificationManager` errors
**Change:** replace `print(...)` with `NSLog` and bubble through `OdinDiagnostics` from #14.

**Files:** `Odin/Features/Todos/NotificationManager.swift`.

---

## P4 — Settings completeness ✅

### 17. Make secrets/setup re-accessible ✅
**Done.** `SettingsView` now has a Connection section with:
- SSH username text field bound to `@AppStorage(TerminalViewModel.sshUsernameKey)`. `TerminalViewModel.sshUsername` is now read from `UserDefaults` (no more hard-coded `mikael_lovholm_gmail_com`); `performConnect()` falls to `.setupRequired` if it's empty; `TerminalContainerView.setupView` has a new first step prompting for it.
- Cloud Function API key — saved indicator + "Replace…" button that swaps to a `SecureField` + Save/Cancel.
- SSH public key — fetched via `SSHKeyManager.getPublicKeyOpenSSH()` on appear, displayed truncated, with a Copy button.
- Claude binary path (macOS only) — shows `ClaudePath.resolve()` result + override field bound to `@AppStorage(ClaudePath.overrideKey)`. `ClaudePath.resolve()` now consults the override before the allow-list (still no shell fallback).
- iOS: added a `Settings` tab (`AppTab.settings`) reachable from any context; removed the gear from `TodoListView`'s toolbar so Settings has a single canonical entry point.

**Files:** `SettingsView.swift`, `TerminalViewModel.swift`, `TerminalContainerView.swift`, `ClaudePath.swift`, `ContentView.swift`, `TodoListView.swift`.

### 18. Add a Disconnect button to iOS terminal ✅
**Done.** Added an `xmark.circle` button to the iOS connected-state overlay stack in `TerminalContainerView`, wired to `viewModel.disconnect()`. Since the tab bar is hidden while connected on iOS, this is the only in-app way to drop the SSH session short of force-killing the app.

**Files:** `Odin/Features/Terminal/TerminalContainerView.swift`.

---

## P5 — Code organization & smells (partial)

### 19. Extract `ReviewFinding` predicates out of `ReviewPaneView` ✅
**Done.** Moved `isDispatchable` / `isUnfixedAny` / `isUnfixedBlocker` / `isUnfixedFixable` / `isUnfixed` into `Odin/Features/OdinMCP/ReviewModels.swift` (where `ReviewFinding` itself is declared — the plan's `Claude/Review/ReviewModels.swift` path didn't exist).

### 20. De-duplicate `ProcessBridge` / `ShellProcessBridge` ✅
**Done.** Added `Odin/Features/Claude/Support/LocalProcessClosureDelegate.swift` with closure-based `LocalProcessDelegate`. Both view models now reference the shared type; the private duplicates are gone.

### 21. Consolidate `runGit` into a shared helper ✅
**Done.** Added `Odin/Features/Claude/Support/GitCommand.swift` with `static func run(_ args:[String], cwd:String) async -> Result` where `Result` exposes `stdout`, `stderr`, `exitCode`, and a `.combined` accessor for the historic "merge both pipes" behaviour. `WorktreeService` and `DiffService` switched to `.combined`; `ProjectService` switched to `.stdout` to preserve its historical behaviour of dropping stderr (avoids interleaving warnings into the parsed ls-files output).

### 22. Split `BackgroundClaudeRunner` — deferred
**Decision:** the file is 521 lines with clear MARK-divided sections and every method touches `BackgroundClaudeRunner` instance state. Extracting `MCPConfigWriter` / `ReviewRunObserver` / `BackgroundNotificationDispatcher` would require either (a) passing the runner into each helper or (b) duplicating state. Neither improves readability. Revisit if the file grows or a second worker spawner emerges.

### 23. Hidden-button shortcut helper ✅
**Done.** Added `Odin/Shared/InvisibleShortcut.swift` with `InvisibleShortcut(_:modifiers:action:)` plus a `.invisibleShortcutsContainer()` view modifier that wraps the `frame(0,0) + opacity(0) + allowsHitTesting(false)` boilerplate. Applied at `ClaudeSessionDetailView.paneShortcuts` (4 shortcuts) and `ClaudeSessionListView.keyboardShortcuts` (⌘1…⌘9 block).

---

## P6 — Dead code ✅

### 24. Delete or wire up
**Deleted:**
- `TerminalRepresentable.onTitleChanged` field on both platforms + `Coordinator` plumbing (init param, stored property, and the `setTerminalTitle` forwarding call). Replaced with a no-op `setTerminalTitle` so the `TerminalViewDelegate` conformance still holds.
- `LocalTerminalViewModel.dismissAllBackgroundNotifications()` — no callers.
- `NotificationManager.cancelAllReminders()` — no callers.
- `.onReceive(... .odinCreateNewNote)` in `NoteListView`'s iOS NavigationStack and `.onReceive(... .odinCreateNewTodo)` in `TodoListView`'s iOS NavigationStack — these notifications are only posted from the macOS-only `CommandGroup` in `OdinApp`.

**Kept (plan was stale):**
- `OdinTerminalView.lastAppliedSize` is actually read on the next line (`if newSize != lastAppliedSize` size-change guard) — not dead.
- No empty `//` lines exist at `BackgroundClaudeRunner.swift:117, 121` — file was already clean.

**Not touched (out of scope without confirmation):**
- `multiple.md` and `PLAN.md` — historical planning docs; leaving them in place rather than silently deleting.

---

## P7 — Accessibility ✅

### 25. Add `.accessibilityLabel` to icon-only buttons
**Done.** Added `.accessibilityLabel` next to the existing `.help(...)` on:
- `ClaudeSessionRow.removeButton` ("Remove session")
- `NoteListView`'s `NoteRow.removeButton` ("Delete note")
- `ClaudeSessionListView` header `+` button ("New Claude session")
- `ContentView`'s in-tabbar About button ("About Odin")
- `NoteListView` macOS-only search-clear button ("Clear search")
- `NoteListView` macOS header `+` button ("New note")
- `ProjectPanelView` refresh button ("Refresh project tree")

---

## Ordering

Implement in numeric order; P0/P1 are safe to ship as small individual PRs. P5/P6 land best as a single cleanup PR. P2 (docs) should follow P0–P1 so it documents the new state, not the old one.

## Out of scope (explicitly)

- The 8-hex tempfile collision risk (`writeMCPConfig`) — vanishingly low in practice; not worth the diff.
- `HSplitView` minWidth budgeting — taste call; flag if users complain.
- `HTTPRequestParser` pipelining — current MCP client opens one request per connection; not exploitable.
- `UnifiedDiffParser` empty-hunk fallback — git never emits it.
