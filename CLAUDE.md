# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build System

This project uses **XcodeGen** to generate the Xcode project from `project.yml`.

```bash
# Regenerate Xcode project after changing project.yml
xcodegen generate

# Build iOS target
xcodebuild -project Odin.xcodeproj -scheme Odin_iOS -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build macOS target
xcodebuild -project Odin.xcodeproj -scheme Odin_macOS build
```

There are no tests, linter, or formatter configured.

## Architecture

**Odin** is a personal productivity app (Todos, Notes, Terminal/SSH) for iPhone and Mac, built as a single multiplatform SwiftUI project targeting iOS 18+ and macOS 15+.

### Data & Sync
- **SwiftData** with `@Model` macro for persistence. All model properties must have defaults (CloudKit requirement).
- **CloudKit** syncs data automatically via iCloud — no custom networking or auth needed.
- `ModelContainer` is set up in `OdinApp.swift` and injected via SwiftUI environment.

### Navigation
`ContentView.swift` uses a `TabView` with `AppTab` enum (`claude` on macOS, then `terminal`, `notes`, `todos`). A `@State` binding controls the selected tab. The Terminal view receives a `$selectedTab` binding to navigate back to Todos programmatically (since the tab bar is hidden when connected). Default tab is `.claude` on macOS, `.todos` on iOS.

### Feature Modules
Each feature lives in `Odin/Features/<Name>/` with its own views and services. Models live in `Odin/Models/`. Todos (Phase 1) and Notes (Phase 2) are complete. Terminal/SSH (Phase 3) core flow works but is missing: iOS keyboard accessory bar, font size control, and auto-reconnect. Claude Terminal (macOS-only) launches Claude Code CLI in a local terminal. OdinMCP (macOS-only) gives those Claude sessions an in-process MCP server for spawning headless background workers. See `PLAN.md` for full details.

### Key Patterns
- `@Query` for reactive SwiftData fetching in list views
- `@Bindable` for mutating model properties in child views
- Sheet presentation for create/edit flows
- `NotificationManager` singleton wraps `UNUserNotificationCenter` for reminder scheduling

### Terminal Feature
Uses SwiftTerm (terminal emulation) + Citadel (SSH) to connect to a GCP VM. Key components:

- **TerminalContainerView** — orchestrates connection flow, overlay buttons (keyboard dismiss, navigate to Todos), mounts the iOS accessory bar via `.safeAreaInset` when the keyboard is up, applies `FontZoomShortcuts` on macOS
- **TerminalRepresentable** — `UIViewRepresentable`/`NSViewRepresentable` wrapping SwiftTerm's `TerminalView`; the iOS variant adds a pinch recognizer that writes the new size through `@AppStorage(TerminalFontSettings.key)`
- **TerminalAccessoryBar** (iOS) — SwiftUI bar with Esc/Tab/Ctrl/arrows/^C/^D/^Z/^L/^R; Ctrl is a sticky toggle. Implemented in SwiftUI because SwiftTerm's `TerminalView.inputAccessoryView` isn't open.
- **TerminalFontSettings** / **FontZoomShortcuts** — persisted font size shared by both terminals. Cmd+= / Cmd+- / Cmd+0 on macOS; pinch on iOS; slider in Settings.
- **TerminalViewModel** — `@Observable` state machine (idle → checkingKey → setupRequired → startingVM → connecting → connected → disconnected → reconnecting → error). Auto-reconnect with [2, 5, 10, 20, 30]s backoff on unexpected drops; user-initiated `cancelConnect`/`disconnect` suppresses it.
- **VMStarterService** — calls Cloud Function to start VM and get IP + SSH host key. Authenticates via `X-API-Key` header. Refuses to connect if host key is missing. Maps the function's HTTP 429 (rate-limit) response to `VMStarterError.rateLimited(retryAfter:)`.
- **SSHService** — Citadel SSH client with Ed25519 auth and mandatory host key verification via `.trustedKeys()`. The full OpenSSH key string (e.g. `ssh-ed25519 AAAA...`) is passed from the Cloud Function response.
- **SSHKeyManager** — Ed25519 key generation and Keychain storage (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Optional biometric protection via `SecAccessControlCreateWithFlags(.biometryCurrentSet)`; `setBiometricProtection(_:)` re-stores the existing key without regenerating so the GCP-side public key stays valid. Toggled from Settings.
- **APIKeyManager** — Stores the Cloud Function API key in Keychain. No secrets in source code. The setup screen prompts for the key on first use.
- **OdinTerminalView** — iOS subclass of `TerminalView` adding mouse wheel events (SGR escape sequences for tmux scroll), tap-to-focus gesture, pinch-to-zoom that updates `TerminalFontSettings`, and UIScrollView pan blocking when mouse mode is active

### Claude Terminal Feature (macOS only)
Uses SwiftTerm's `LocalProcess` to spawn the Claude Code CLI in a local PTY — no SSH or Cloud Function needed. Lives in `Odin/Features/Claude/`. Guarded by `#if os(macOS)` so iOS compilation is unaffected.

Multi-session: the Claude tab is a split view with a sidebar listing all sessions and a detail pane showing the selected session's terminal. Sessions persist as directory paths in `UserDefaults` (key `claude.sessionDirectories`) and are restored in `.notStarted` state on launch — clicking a row starts Claude in that directory.

Adding a session prompts twice: an `NSOpenPanel` picks the source repo, then an `NSAlert` with a text field asks for a worktree name. `WorktreeService.create(sourcePath:name:)` validates the name (no empty, no `-` prefix, no path/glob/ref-special chars, no `..`), runs `git rev-parse --git-dir` (must succeed), then `git worktree add -b <name> -- <parent>/<base>--<name>` where `<base>` is the source folder's name stripped of any existing `--suffix` (so worktrees of worktrees stay flat). The session is opened in the new worktree path, not the selected folder.

- **ClaudeSession** — `@Observable` model for one session: `id`, `workingDirectory`, `displayName` (folder's last path component), and an owned `LocalTerminalViewModel`. The view model survives detail-view rebuilds so the process keeps running across session switches (though scrollback resets, since SwiftUI creates a new `TerminalView` per `.id(session.id)` mount).
- **ClaudeSessionStore** — `@Observable` store injected via `@Environment` from `OdinApp`. Holds the session list and `selectedSessionID`. `addSession(directory:)` creates and persists; `select(_:)` sets selection and auto-starts Claude if `.notStarted`; `remove(_:)` calls `LocalProcess.terminate()`, drops the session, and persists.
- **ClaudeSessionListView** — Claude tab content. `HSplitView` with sidebar (header + `+` button + `List` of `ClaudeSessionRow`) and detail (`ClaudeSessionDetailView`). Hidden buttons in the view's `.background` register ⌘1…⌘9 to jump to the first nine sessions.
- **ClaudeSessionRow** — two independent indicators. Left side: an 8pt session-status dot with four states, evaluated in this priority order: `!running` → grey, `awaitingInput` → green, `isActive` → yellow pulsing, `isSelected` → grey, `didFinish` → yellow stable, default → grey. Two consequences worth knowing: (1) `awaitingInput` is the highest-priority signal, beating both selection and the working pulse — so a session blocked on a permission prompt or slash-command menu shows green even when the user is looking at it; (2) selection only forces grey when the session is idle, not when Claude needs the user. `awaitingInput` is set either by Claude Code's `Notification` hook (via `odin-status.sh awaiting-input`) or by the PTY-output heartbeat in `LocalTerminalViewModel` (catches menus/prompts that don't fire `Notification`). It clears only when Claude resumes streaming output (`noteDataReceived`) or transitions through `working`/`idle` (`applyHookState`) — clicking the row does NOT acknowledge it, because looking isn't the same as responding. `didFinish` (yellow stable) IS cleared on click and on being-watched, via `acknowledge()`. Right of the folder name: an optional green `checkmark.circle.fill` shown when `pendingNotifications` is non-empty (a background task spawned by this session has completed). "⌘N" hint on the far right for the first nine rows. Right-click → Remove.
- **ClaudeSessionDetailView** — wraps `TerminalRepresentable` with state overlays (`.starting` spinner, `.exited` / `.error` retry overlays). Calls `makeFirstResponder` on the terminal in `.onAppear` and when state becomes `.running`, so selecting a row puts focus in the terminal immediately.
- **LocalTerminalViewModel** — `@Observable` state machine (notStarted → starting → running → exited → error). Resolves the `claude` binary path via `ClaudePath.resolve()` (checks `/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, then falls back to `which claude` via login shell). Each start mints a per-launch `sessionId` ("s-<8 hex>"), sets `ODIN_SESSION_ID` in the child env, and writes a per-launch `.mcp.json` to `$TMPDIR` that points the child at the OdinMCP server (carries the session id as the `X-Session-Id` header). The view model registers itself with `OdinSessionRegistry` so background runners can find it to push notifications. Spawns the process with `TERM=xterm-256color` and `COLORTERM=truecolor`. Handles terminal resize via `TIOCSWINSZ` ioctl on the PTY — sizes are converted with `UInt16(clamping:)` because the embedded HSplitView can hand the terminal transient zero/negative dimensions during layout. Drives sidebar status (`isActive`, `awaitingInput`, `didFinish`) from two sources: (a) a per-session state file at `~/.claude/odin-status/<sessionId>.state` that the `odin-status.sh` Claude Code hook writes (`working` on `UserPromptSubmit`, `idle` on `Stop`, `awaiting-input` on `Notification`, deleted on `SessionEnd`); the view model pre-creates the file and attaches a `DispatchSourceFileSystemObject` watcher on it — every hook write retriggers `applyHookState`. (b) A 500ms PTY-output heartbeat (`DispatchSource` timer + `lastDataReceivedAt` timestamp set by `noteDataReceived` from the `ProcessBridge.onData` closure). While `isActive` is true but no PTY bytes have arrived for `heartbeatIdleThreshold` (2s), the heartbeat promotes the session to `awaitingInput`. This catches `/`-command menus and other interactive prompts that don't fire Claude Code's `Notification` hook. The heartbeat also demotes back to active as soon as bytes resume flowing. This replaced the previous approach of parsing the spinner braille char out of the terminal title, which was fragile across Claude Code TUI versions. Also exposes `pendingNotifications: [BackgroundNotification]` for the OdinMCP background-task checkmark. `terminate()` forwards to `LocalProcess.terminate()` (SIGTERM + FD cleanup) and deregisters from the session registry.
- **ProcessBridge** — `@MainActor` adapter conforming to `LocalProcessDelegate`. Bridges process callbacks (data received, terminated, window size) to the view model via closures. All callbacks dispatched on the main queue.

### OdinMCP — Background Claude Workers (macOS only)
Lives in `Odin/Features/OdinMCP/`. Boots from `OdinApp.init` (macOS-only `Task { @MainActor in ... }` block) which installs skills + hooks and starts the MCP server. Each Odin Claude tab launches with `--mcp-config` pointing at the server, so its Claude session can spawn headless `claude -p` workers and route completion notifications back to its UI.

- **OdinMCPServer** — `@MainActor` singleton. `NWListener` on `127.0.0.1` with an ephemeral port (`requiredLocalEndpoint` + an application-layer endpoint check enforce loopback-only). Speaks MCP JSON-RPC 2.0 over HTTP at `POST /mcp`. Handles `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`. Extracts `X-Session-Id` from request headers and stores it in `CurrentMCPRequest.sessionId` (a `@TaskLocal`) for the duration of each request.
- **HTTPRequestParser** — minimal HTTP/1.1 head + Content-Length parser, one-shot per connection. Marked `@unchecked Sendable` because all access happens on the `.main` queue.
- **OdinMCPTools** — three tools: `run_background_task(prompt, cwd?, model?)` returns immediately with a `task_id` (optional `model` pins the worker to a specific Claude model id, e.g. `claude-sonnet-4-6`; omit to use the host CLI default); `get_task_status(task_id)` is non-blocking; `await_task(task_id, timeout_seconds?)` blocks until done (avoid — it turns "background" into "synchronous" from the parent's perspective).
- **BackgroundTaskRegistry** — `@MainActor` singleton keyed by `t-<8 hex>`. Soft cap of 50 retained runners: running tasks are never evicted; the oldest completed/failed entries fall off when the registry grows past the cap.
- **BackgroundClaudeRunner** — wraps `Foundation.Process` to spawn `claude -p "<prompt>" --dangerously-skip-permissions` (with `--model <id>` appended when the tool call supplied one). Captures stdout/stderr through pipes. On exit: (a) writes a notification to `~/.claude/odin-pending/<parent_session_id>.txt` for the hook to drain on next user prompt; (b) pushes a `BackgroundNotification` into the parent tab's `LocalTerminalViewModel.pendingNotifications` so the sidebar indicator lights up.
- **OdinSessionRegistry** — weakly maps per-launch `sessionId → LocalTerminalViewModel`. Read by `BackgroundClaudeRunner.pushBannerToParent` to find which Claude tab to notify.
- **OdinSkillInstaller** — on app launch, writes `~/.claude/skills/odin-spawn/SKILL.md`, `~/.claude/skills/odin-orchestrate/SKILL.md`, and `~/.claude/skills/odin-review/SKILL.md`. Always overwrites, so source edits in this file propagate on relaunch. The skills teach Claude when and how to call the MCP tools (lead with the pull pattern — fire-and-forget, then check status on a later turn or rely on the auto-notification hook). `odin-review` is a two-phase branch-review skill (read-only review workers, then opt-in fix workers) that pins workers to Sonnet 4.6 via the `model` arg.
- **OdinHookInstaller** — writes two hook scripts (chmod 755) and merges matching entries into `~/.claude/settings.json` idempotently (skips if the exact `command` string already appears under that event). Both scripts key off `$ODIN_SESSION_ID` in the parent claude env. (1) `~/.claude/hooks/odin-pending.sh` — registered for `UserPromptSubmit`; drains `~/.claude/odin-pending/<sessionId>.txt` to stdout so completed-background-task summaries get injected into Claude's next turn. (2) `~/.claude/hooks/odin-status.sh <state>` — registered for `UserPromptSubmit` (`working`), `Stop` (`idle`), `Notification` (`awaiting-input`), and `SessionEnd` (`delete`); writes the named state into `~/.claude/odin-status/<sessionId>.state`. `LocalTerminalViewModel`'s file watcher picks up every write and updates the sidebar dot.

#### Identity flow
`LocalTerminalViewModel.startClaude()` mints `sessionId = "s-<8 hex>"` and uses it in three places: the spawned claude's env (`ODIN_SESSION_ID=...`), the `.mcp.json` it writes (`headers: { X-Session-Id: ... }`), and `OdinSessionRegistry.register(self, for: sessionId)`. Every tool call from that tab carries the id; the server stuffs it into a TaskLocal; the runner stores it on creation; on completion the runner uses it to route both the pending file (consumed by the hook → Claude's context) and the UI banner (consumed by the sidebar → the human's eyes).

#### User-facing notification surface
- **Sidebar checkmark** (`ClaudeSessionRow`): green `checkmark.circle.fill` when `pendingNotifications` is non-empty; otherwise the existing active-state green dot.
- **Auto-dismiss on click**: `ClaudeSessionStore.select(_:)` snapshots the pending notifications visible at click time and dismisses only those, so a worker that completes between the click and a future MainActor tick gets its own row + checkmark instead of being silently cleared.
- **Context injection on next user prompt**: the `UserPromptSubmit` hook drains the pending file and prints its contents to stdout, which Claude Code prepends to Claude's next turn — so Claude sees the result even after the sidebar signal has been cleared by the user opening the tab.

#### Files written outside the repo (macOS only, on app launch)
- `~/.claude/skills/odin-spawn/SKILL.md`, `~/.claude/skills/odin-orchestrate/SKILL.md`, `~/.claude/skills/odin-review/SKILL.md` — always overwritten.
- `~/.claude/hooks/odin-pending.sh`, `~/.claude/hooks/odin-status.sh` — always overwritten, chmod 755.
- `~/.claude/settings.json` — hook entries merged idempotently under `hooks.UserPromptSubmit`, `hooks.Stop`, `hooks.Notification`, `hooks.SessionEnd` (atomic write).
- `~/.claude/odin-pending/<sessionId>.txt` — per-session pending notifications (drained by the hook). Removed by `LocalTerminalViewModel.tearDownCurrentSession()` on session restart/terminate; stale files only survive if a worker writes one after teardown (harmless).
- `~/.claude/odin-status/<sessionId>.state` — per-session Claude lifecycle state written by `odin-status.sh` (`working`/`idle`/`awaiting-input`); pre-created by `LocalTerminalViewModel.startStatusWatcher` so a kqueue file source can observe in-place overwrites. Deleted on `SessionEnd` and on `tearDownCurrentSession()`.
- `$TMPDIR/odin-mcp-<random>.json` — per-launch MCP config. Removed by `LocalTerminalViewModel.tearDownCurrentSession()` on session restart/terminate.

### Claude Diff Side Panel (macOS only)
Lives in `Odin/Features/Claude/Diff/`. Renders an uncommitted-changes view (git status + per-file unified diff) inside each Claude session's detail view. Toggleable with ⇧⌘D; visibility persists in `@AppStorage("claude.diffPaneVisible")`. Each `ClaudeSession` owns one `DiffViewModel` so file list + selection survive detail-view rebuilds (same pattern as the terminal view model).

- **DiffPaneView** — `HSplitView`-friendly column with a header, file list (`ChangedFileRow`), and a `UnifiedDiffView` body. Calls `viewModel.activate()` / `deactivate()` in `.onAppear` / `.onDisappear` so the FSEvents watcher only runs while visible.
- **DiffViewModel** — `@Observable` per-session state. Holds `files`, `selectedFileID`, `selectedDiff` (parsed hunks), `selectedIsBinary`, `selectedTruncated`. Two monotonic counters (`refreshGeneration`, `loadGeneration`) discard stale async results when the watcher fires faster than git completes or the user re-selects mid-load. Capped at `renderLineCap = 2_000` lines per file to keep `LazyVStack` happy on huge diffs (`*.pbxproj` etc.).
- **DiffService** — read-only async wrappers around `git status --porcelain=v1 -z --untracked-files=all`, `git diff --numstat -M HEAD`, and `git diff --no-color -M HEAD -- <path>` (untracked files use `--no-index /dev/null <path>` to render the whole file as additions). Runs each process on `DispatchQueue.global(qos: .userInitiated)` via `withCheckedContinuation` so the UI thread never blocks on git. Untracked-file +/- counts come from a lightweight in-process line counter that also flags binaries on a NUL byte in the first 8 KB.
- **UnifiedDiffParser** — splits raw `git diff` output into `DiffHunk`s, parses `@@ -a,b +c,d @@` headers for line-number tracking, drops file-header preamble (`diff --git`, `index`, `+++`, `---`).
- **UnifiedDiffView** — renders hunks with GitHub-style two-column line gutters, +/− markers, green/red row tints, and a sticky-ish hunk header. Per-line text goes through `SyntaxHighlighter.shared.highlight(...)`. Shows a truncation footer when `isTruncated`.
- **SyntaxHighlighter** — `@MainActor` singleton wrapping Highlightr in `fastRender: true` mode (no WKWebView). Caches highlighted lines keyed by `language|theme|content` (cap 4 000); on overflow the cache is dropped wholesale (cheap, since hits dominate). Strips Highlightr's background attribute so the add/remove row tint shows through, keeps foreground colors. Theme switches between `atom-one-dark` / `atom-one-light` based on the current `colorScheme`.
- **WorktreeWatcher** — recursive FSEvents stream rooted at the worktree path, latency 0 + own debounce (300 ms), file-level events, skips paths matching `/.git/` or ending in `/.git` so git's own writes don't trigger a refresh storm. Lifecycle managed by `DiffViewModel.activate()` / `.deactivate()`.

Dependency: adds `Highlightr` (`raspu/Highlightr`, from 2.2.0) to `project.yml`, gated to `platforms: [macOS]`.

### Claude Shell Pane (macOS only)
Lives in `Odin/Features/Claude/ShellTerminalViewModel.swift`. Adds a second terminal below each Claude session — a plain login `zsh` rooted at the session's working directory, useful for running git commands or scripts alongside Claude. Toggleable with ⇧⌘T; visibility persists in `@AppStorage("claude.shellPaneVisible")` (default `false`). The detail view stacks the existing top area (terminal + optional diff pane) and the shell pane in a `VSplitView`. Each `ClaudeSession` owns one `ShellTerminalViewModel` so the zsh process and scrollback survive detail-view rebuilds (same pattern as `viewModel` and `diffViewModel`).

- **ShellTerminalViewModel** — `@Observable` `@MainActor` state machine (notStarted → running → exited → error). Spawns `/bin/zsh -l` via SwiftTerm's `LocalProcess`, inherits the parent env plus `TERM=xterm-256color`, `COLORTERM=truecolor`, and a fallback `LANG=en_US.UTF-8`. `startIfNeeded()` is idempotent (`guard state == .notStarted`) so the `.onAppear` in `shellPane` is safe to fire repeatedly. `restart()` and `terminate()` bump a monotonic `currentLaunchToken` before tearing down the old `LocalProcess`; the bridge's `onTerminated` closure captures the launch token at start time and bails if it no longer matches, so a late SIGTERM callback from the old process can't clobber the new process's `.running` state.
- **ShellProcessBridge** — minimal `LocalProcessDelegate` adapter, same `nonisolated` + `MainActor.assumeIsolated` shape as `ProcessBridge` in `LocalTerminalViewModel`. No heartbeat, no status hook, no MCP wiring — this is just a dumb shell.
- `ClaudeSessionStore.remove(_:)` now terminates `shellViewModel` in addition to `viewModel`.

### Keyboard Shortcut Reshuffle
To make ⇧⌘T available for the shell pane toggle, "New Todo" moved from ⇧⌘T to ⌥⌘T in `OdinApp.commands`. ⇧⌘N (New Note) and ⌘N (New Claude Session) are unchanged. `ContentView` now appends the ⌃1…⌃4 tab-switch hints inline in the macOS tab titles (`"Claude  ⌃1"`, etc.) since `Tab` doesn't render menu shortcuts. The sidebar shortcut-hint footer in `ClaudeSessionListView` lists New session / Diff pane / Terminal pane via a small helper.

### App-Level Glue

- **OdinApp** owns `selectedTab` and the `ClaudeSessionStore` (macOS). Wraps `ContentView` in `ThemedContainer`. On macOS adds `CommandGroup(replacing: .newItem)` with three creation actions: New Claude Session (⌘N, posts `.odinCreateNewClaudeSession`), New Note (⇧⌘N, posts `.odinCreateNewNote`), New Todo (⌥⌘T, posts `.odinCreateNewTodo` — moved off ⇧⌘T which is now the shell-pane toggle). A `Go` `CommandMenu` exposes tab switching as ⌃1…⌃4 (Claude / Terminal / Notes / Todos) — chosen over ⌘1…9 to avoid colliding with the Claude tab's per-session shortcuts. ⌘N is safe alongside the per-session ⌘1…⌘9 because the digit keys are distinct. Also adds a `Settings` scene.
- **SettingsView** — appearance (system/light/dark), accent color, terminal font slider, biometric SSH protection toggle. Available via ⌘, on macOS and a gear icon in the Todos toolbar on iOS.
- **CloudKitSyncMonitor** — `@Observable` singleton observing `NSPersistentCloudKitContainer.eventChangedNotification`. `CloudKitSyncStatusView` is mounted in both list toolbars and lights up `exclamationmark.icloud.fill` when the last sync errored.
- **MarkdownTextEditor** — UIViewRepresentable (UITextView) / NSViewRepresentable (NSTextView subclass) that intercepts ⌘B / ⌘I / ⌘K to wrap the current selection in `**…**` / `*…*` / `[text](url)`. Used in `NoteDetailView` instead of SwiftUI's `TextEditor` because the latter doesn't expose selection.

### Cloud Function
Source lives in `cloud-functions/claude-dev-starter/`. Node.js function deployed to GCP (`europe-north1`). In-memory rate limit: 10 cold starts per rolling hour per instance; returns HTTP 429 with `Retry-After` once the budget is spent (reads of `RUNNING` VMs are unbounded).



```bash
# Deploy (requires gcloud CLI authenticated)
gcloud functions deploy claude-dev-starter --gen2 --region=europe-north1 \
  --project=claude-dev-ml-01 --runtime=nodejs22 --trigger-http \
  --allow-unauthenticated --set-env-vars=API_KEY=<key> \
  --source=cloud-functions/claude-dev-starter --entry-point=claude-dev-starter
```

The function validates an `X-API-Key` header (secret stored in `API_KEY` env var), starts the VM if stopped, and returns `{status, ip, hostKey}`. The `hostKey` is the full OpenSSH public key string (e.g. `ssh-ed25519 AAAA...`) read from VM instance metadata key `ssh-host-key-ed25519`. If the VM's host key ever changes (e.g. OS reinstall), update the metadata: `gcloud compute instances add-metadata claude-dev-vm --zone=europe-north1-a --project=claude-dev-ml-01 --metadata=ssh-host-key-ed25519=<base64-key>`

### Security
- **API key**: Stored in Keychain on device, validated by Cloud Function. Never committed to source code.
- **SSH host key**: Mandatory verification on every connect. The Cloud Function returns the expected host key; the app rejects connections if the server key doesn't match.
- **SSH private key**: Ed25519, stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no iCloud sync).
- **DEVELOPMENT_TEAM**: Left empty in `project.yml` — set manually in Xcode. Do not commit team IDs to the pbxproj.

## Platform Considerations

- Single codebase targets both iOS and macOS via `platform: [iOS, macOS]` in `project.yml`
- XcodeGen produces two schemes: `Odin_iOS` and `Odin_macOS`
- `UILaunchScreen: {}` in `project.yml` is required — without it iOS runs in compatibility zoom mode
- Code signing requires manually setting Development Team in Xcode; CloudKit sync requires the iCloud capability enabled
- Terminal tab bar is hidden when connected on iOS; overlay buttons provide keyboard dismiss and tab navigation
- The Claude tab is macOS-only (`#if os(macOS)` on both the `AppTab.claude` enum case and the `Tab` in `ContentView`). New files in `Odin/Features/Claude/` are fully wrapped in `#if os(macOS)` so they compile to nothing on iOS.
- Claude terminal requires the `claude` CLI installed on the Mac (e.g. via `npm install -g @anthropic-ai/claude-code`). The app is not sandboxed, so spawning local processes works.
