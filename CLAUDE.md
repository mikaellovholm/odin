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
Each feature lives in `Odin/Features/<Name>/` with its own views and services. Models live in `Odin/Models/`. Todos (Phase 1) and Notes (Phase 2) are complete. Terminal/SSH (Phase 3) core flow works but is missing: iOS keyboard accessory bar, font size control, and auto-reconnect. Claude Terminal (macOS-only) launches Claude Code CLI in a local terminal. See `PLAN.md` for full details.

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

- **ClaudeTerminalContainerView** — SwiftUI view reusing `TerminalRepresentable`. Shows progress spinner while starting, terminal when running, restart/retry overlays on exit/error.
- **LocalTerminalViewModel** — `@Observable` state machine (starting → running → exited → error). Resolves the `claude` binary path (checks `/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, then falls back to `which claude` via login shell). Spawns the process with `TERM=xterm-256color` and `COLORTERM=truecolor`. Handles terminal resize via `TIOCSWINSZ` ioctl on the PTY. Exposes `isActive` based on Claude Code's terminal title: Claude sets the title prefix to a braille spinner (`⠂` U+2802 / `⠐` U+2810) when working and `✳` (U+2733) when idle. `handleTitleChanged(_:)` receives OSC 0 title updates via `TerminalRepresentable`'s `onTitleChanged` callback.
- **ProcessBridge** — `@MainActor` adapter conforming to `LocalProcessDelegate`. Bridges process callbacks (data received, terminated, window size) to the view model via closures. All callbacks dispatched on the main queue.

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
