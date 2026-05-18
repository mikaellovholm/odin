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
`ContentView.swift` uses a `TabView` with `AppTab` enum (`todos`, `notes`, `terminal`, and `claude` on macOS). A `@State` binding controls the selected tab. The Terminal view receives a `$selectedTab` binding to navigate back to Todos programmatically (since the tab bar is hidden when connected).

### Feature Modules
Each feature lives in `Odin/Features/<Name>/` with its own views and services. Models live in `Odin/Models/`. Todos (Phase 1) and Notes (Phase 2) are complete. Terminal/SSH (Phase 3) core flow works but is missing: iOS keyboard accessory bar, font size control, and auto-reconnect. Claude Terminal (macOS-only) launches Claude Code CLI in a local terminal. OdinMCP (macOS-only) gives those Claude sessions an in-process MCP server for spawning headless background workers. See `PLAN.md` for full details.

### Key Patterns
- `@Query` for reactive SwiftData fetching in list views
- `@Bindable` for mutating model properties in child views
- Sheet presentation for create/edit flows
- `NotificationManager` singleton wraps `UNUserNotificationCenter` for reminder scheduling

### Terminal Feature
Uses SwiftTerm (terminal emulation) + Citadel (SSH) to connect to a GCP VM. Key components:

- **TerminalContainerView** — orchestrates connection flow, overlay buttons (keyboard dismiss, navigate to Todos)
- **TerminalRepresentable** — `UIViewRepresentable`/`NSViewRepresentable` wrapping SwiftTerm's `TerminalView`
- **TerminalViewModel** — `@Observable` state machine (idle → checkingKey → setupRequired → startingVM → connecting → connected → disconnected → error)
- **VMStarterService** — calls Cloud Function to start VM and get IP + SSH host key. Authenticates via `X-API-Key` header. Refuses to connect if host key is missing.
- **SSHService** — Citadel SSH client with Ed25519 auth and mandatory host key verification via `.trustedKeys()`. The full OpenSSH key string (e.g. `ssh-ed25519 AAAA...`) is passed from the Cloud Function response.
- **SSHKeyManager** — Ed25519 key generation and Keychain storage (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- **APIKeyManager** — Stores the Cloud Function API key in Keychain. No secrets in source code. The setup screen prompts for the key on first use.
- **OdinTerminalView** — iOS subclass of `TerminalView` adding mouse wheel events (SGR escape sequences for tmux scroll), tap-to-focus gesture, and UIScrollView pan blocking when mouse mode is active

### Claude Terminal Feature (macOS only)
Uses SwiftTerm's `LocalProcess` to spawn the Claude Code CLI in a local PTY — no SSH or Cloud Function needed. Lives in `Odin/Features/Claude/`. Guarded by `#if os(macOS)` so iOS compilation is unaffected.

Multi-session: the Claude tab is a split view with a sidebar listing all sessions and a detail pane showing the selected session's terminal. Sessions persist as directory paths in `UserDefaults` (key `claude.sessionDirectories`) and are restored in `.notStarted` state on launch — clicking a row starts Claude in that directory.

- **ClaudeSession** — `@Observable` model for one session: `id`, `workingDirectory`, `displayName` (folder's last path component), and an owned `LocalTerminalViewModel`. The view model survives detail-view rebuilds so the process keeps running across session switches (though scrollback resets, since SwiftUI creates a new `TerminalView` per `.id(session.id)` mount).
- **ClaudeSessionStore** — `@Observable` store injected via `@Environment` from `OdinApp`. Holds the session list and `selectedSessionID`. `addSession(directory:)` creates and persists; `select(_:)` sets selection and auto-starts Claude if `.notStarted`; `remove(_:)` calls `LocalProcess.terminate()`, drops the session, and persists.
- **ClaudeSessionListView** — Claude tab content. `HSplitView` with sidebar (header + `+` button + `List` of `ClaudeSessionRow`) and detail (`ClaudeSessionDetailView`). Hidden buttons in the view's `.background` register ⌘1…⌘9 to jump to the first nine sessions.
- **ClaudeSessionRow** — left status indicator priority: green `checkmark.circle.fill` when `pendingNotifications` is non-empty (a background task spawned by this session has completed); else green dot when Claude is actively working; else empty. Folder name in the middle, "⌘N" hint on the right for the first nine rows. Right-click → Remove.
- **ClaudeSessionDetailView** — wraps `TerminalRepresentable` with state overlays (`.starting` spinner, `.exited` / `.error` retry overlays). Calls `makeFirstResponder` on the terminal in `.onAppear` and when state becomes `.running`, so selecting a row puts focus in the terminal immediately.
- **LocalTerminalViewModel** — `@Observable` state machine (notStarted → starting → running → exited → error). Resolves the `claude` binary path via `ClaudePath.resolve()` (checks `/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, then falls back to `which claude` via login shell). Each start mints a per-launch `sessionId` ("s-<8 hex>"), sets `ODIN_SESSION_ID` in the child env, and writes a per-launch `.mcp.json` to `$TMPDIR` that points the child at the OdinMCP server (carries the session id as the `X-Session-Id` header). The view model registers itself with `OdinSessionRegistry` so background runners can find it to push notifications. Spawns the process with `TERM=xterm-256color` and `COLORTERM=truecolor`. Handles terminal resize via `TIOCSWINSZ` ioctl on the PTY — sizes are converted with `UInt16(clamping:)` because the embedded HSplitView can hand the terminal transient zero/negative dimensions during layout. Exposes `isActive` based on Claude Code's terminal title prefix (braille spinner `⠂`/`⠐` = working, otherwise idle) and `pendingNotifications: [BackgroundNotification]` for the sidebar indicator. `terminate()` forwards to `LocalProcess.terminate()` (SIGTERM + FD cleanup) and deregisters from the session registry.
- **ProcessBridge** — `@MainActor` adapter conforming to `LocalProcessDelegate`. Bridges process callbacks (data received, terminated, window size) to the view model via closures. All callbacks dispatched on the main queue.

### OdinMCP — Background Claude Workers (macOS only)
Lives in `Odin/Features/OdinMCP/`. Boots from `OdinApp.init` (macOS-only `Task { @MainActor in ... }` block) which installs skills + hooks and starts the MCP server. Each Odin Claude tab launches with `--mcp-config` pointing at the server, so its Claude session can spawn headless `claude -p` workers and route completion notifications back to its UI.

- **OdinMCPServer** — `@MainActor` singleton. `NWListener` on `127.0.0.1` with an ephemeral port (`requiredLocalEndpoint` + an application-layer endpoint check enforce loopback-only). Speaks MCP JSON-RPC 2.0 over HTTP at `POST /mcp`. Handles `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`. Extracts `X-Session-Id` from request headers and stores it in `CurrentMCPRequest.sessionId` (a `@TaskLocal`) for the duration of each request.
- **HTTPRequestParser** — minimal HTTP/1.1 head + Content-Length parser, one-shot per connection. Marked `@unchecked Sendable` because all access happens on the `.main` queue.
- **OdinMCPTools** — three tools: `run_background_task(prompt, cwd?)` returns immediately with a `task_id`; `get_task_status(task_id)` is non-blocking; `await_task(task_id, timeout_seconds?)` blocks until done (avoid — it turns "background" into "synchronous" from the parent's perspective).
- **BackgroundTaskRegistry** — `@MainActor` singleton keyed by `t-<8 hex>`. Never evicts (intentional — small enough that leaks aren't a near-term concern).
- **BackgroundClaudeRunner** — wraps `Foundation.Process` to spawn `claude -p "<prompt>" --dangerously-skip-permissions`. Captures stdout/stderr through pipes. On exit: (a) writes a notification to `~/.claude/odin-pending/<parent_session_id>.txt` for the hook to drain on next user prompt; (b) pushes a `BackgroundNotification` into the parent tab's `LocalTerminalViewModel.pendingNotifications` so the sidebar indicator lights up.
- **OdinSessionRegistry** — weakly maps per-launch `sessionId → LocalTerminalViewModel`. Read by `BackgroundClaudeRunner.pushBannerToParent` to find which Claude tab to notify.
- **OdinSkillInstaller** — on app launch, writes `~/.claude/skills/odin-spawn/SKILL.md` and `~/.claude/skills/odin-orchestrate/SKILL.md`. Always overwrites, so source edits in this file propagate on relaunch. The skills teach Claude when and how to call the MCP tools (lead with the pull pattern — fire-and-forget, then check status on a later turn or rely on the auto-notification hook).
- **OdinHookInstaller** — writes `~/.claude/hooks/odin-pending.sh` (chmod 755). The script reads `$ODIN_SESSION_ID` from its parent claude process env and drains the matching pending file. Also merges an entry into `~/.claude/settings.json` under `hooks.UserPromptSubmit` — idempotent (skips if our script path already appears in any existing entry). On the next user prompt, the hook's stdout becomes injected context, so Claude sees completed background results without polling.

#### Identity flow
`LocalTerminalViewModel.startClaude()` mints `sessionId = "s-<8 hex>"` and uses it in three places: the spawned claude's env (`ODIN_SESSION_ID=...`), the `.mcp.json` it writes (`headers: { X-Session-Id: ... }`), and `OdinSessionRegistry.register(self, for: sessionId)`. Every tool call from that tab carries the id; the server stuffs it into a TaskLocal; the runner stores it on creation; on completion the runner uses it to route both the pending file (consumed by the hook → Claude's context) and the UI banner (consumed by the sidebar → the human's eyes).

#### User-facing notification surface
- **Sidebar checkmark** (`ClaudeSessionRow`): green `checkmark.circle.fill` when `pendingNotifications` is non-empty; otherwise the existing active-state green dot.
- **Auto-dismiss on click**: `ClaudeSessionStore.select(_:)` calls `dismissAllBackgroundNotifications()`, so opening the session acknowledges all signals.
- **Context injection on next user prompt**: the `UserPromptSubmit` hook drains the pending file and prints its contents to stdout, which Claude Code prepends to Claude's next turn — so Claude sees the result even after the sidebar signal has been cleared by the user opening the tab.

#### Files written outside the repo (macOS only, on app launch)
- `~/.claude/skills/odin-spawn/SKILL.md`, `~/.claude/skills/odin-orchestrate/SKILL.md` — always overwritten.
- `~/.claude/hooks/odin-pending.sh` — always overwritten, chmod 755.
- `~/.claude/settings.json` — hook entry merged in idempotently under `hooks.UserPromptSubmit`.
- `~/.claude/odin-pending/<sessionId>.txt` — per-session pending notifications (drained by the hook). Stale files survive if the session was removed before its child task drained; they're harmless but accumulate.
- `$TMPDIR/odin-mcp-<random>.json` — per-launch MCP config. Not cleaned up by Odin.

### Cloud Function
Source lives in `cloud-functions/claude-dev-starter/`. Node.js function deployed to GCP (`europe-north1`).

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
