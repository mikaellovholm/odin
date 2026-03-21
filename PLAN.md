# Odin — Implementation Plan

## Context

Build a personal productivity app "Odin" for iPhone and Mac with three independent features: Todos, Notes, and Terminal (SSH). Uses CloudKit for free sync (included with $99 Apple Developer Account). No server infrastructure needed.

## Architecture

```
┌─────────────┐     ┌─────────────┐
│  iPhone App  │     │   Mac App    │
│   SwiftUI    │     │   SwiftUI   │
│  SwiftData   │     │  SwiftData  │
└──────┬───────┘     └──────┬──────┘
       │                    │
       └────── iCloud ──────┘
            (CloudKit)
```

- **Single Xcode multiplatform project** (iOS + macOS from one target)
- **SwiftData + CloudKit** for persistence and sync
- **Local notifications** for todo reminders
- **iCloud auth** — automatic, no login flow

## Project Structure

```
odin/
  Odin.xcodeproj
  Odin/
    OdinApp.swift                    -- @main, ModelContainer + CloudKit setup
    ContentView.swift                -- Root TabView

    Models/
      TodoItem.swift                 -- @Model: title, isCompleted, dueDate, reminderDate
      Note.swift                     -- @Model: title, content (markdown), isPinned
      SSHHostConfig.swift            -- @Model: hostname, port, username, authMethod

    Features/
      Todos/
        TodoListView.swift           -- List with incomplete/completed sections
        TodoRowView.swift            -- Single row, tap to toggle
        TodoDetailView.swift         -- Edit todo, set reminder
        NotificationManager.swift    -- UNUserNotificationCenter wrapper

      Notes/
        NoteListView.swift           -- List with search + pinning
        NoteDetailView.swift         -- Markdown editor + preview toggle
        NoteEditorView.swift         -- Raw TextEditor
        NotePreviewView.swift        -- Rendered markdown (MarkdownUI)

      Terminal/
        TerminalContainerView.swift  -- Orchestrator (start VM → connect → display)
        VMStarter.swift              -- Calls Cloud Function, returns IP, tracks VM status
        SSHConnectionManager.swift   -- Citadel SSH ↔ SwiftTerm data piping
        SSHKeyManager.swift          -- Keychain-based key generation/storage

    Platform/
      iOS/
        iOSTerminalView.swift        -- UIViewRepresentable for SwiftTerm
      macOS/
        macOSTerminalView.swift      -- NSViewRepresentable for SwiftTerm
```

## Dependencies (3 external packages)

| Package | Purpose |
|---------|---------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator view (VT100/xterm) |
| [Citadel](https://github.com/orlandos-nl/Citadel) | SSH client (pure Swift, built on SwiftNIO SSH) |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | Markdown rendering in SwiftUI |

Everything else is built-in Apple frameworks: SwiftData, CloudKit, UserNotifications, Security (Keychain).

## Data Models

All properties have defaults (CloudKit requirement). SSH credentials stored in Keychain, NOT in SwiftData.

- **TodoItem**: id, title, isCompleted, notes, dueDate?, reminderDate?, notificationID?, sortOrder
- **Note**: id, title, content (markdown), createdAt, updatedAt, isPinned
- **SSHHostConfig**: id, label, hostname, port, username, authMethod, privateKeyLabel (Keychain ref)

## Terminal Architecture

### GCP VM Details
- **VM**: `claude-dev-vm` in `europe-north1-a` (e2-small, Ubuntu 24.04)
- **IP**: Ephemeral — obtained via Cloud Function
- **Cloud Function**: `GET https://europe-north1-claude-dev-ml-01.cloudfunctions.net/claude-dev-starter`
  - Starts VM if stopped, returns `{"status": "...", "ip": "..."}`
  - Status: `started` (was stopped, booting), `running` (already up)
- **SSH user**: `mikael_lovholm_gmail_com` (GCP OS Login)
- **Auth**: Ed25519 key (added to GCP via `gcloud compute os-login ssh-keys add`)
- **tmux**: Auto-attaches on SSH — no manual `tmux attach` needed
- **Auto-shutdown**: 20 min with no SSH sessions

### Connection Flow
1. App calls Cloud Function → VM starts + returns IP
2. Show status (stopped → starting → running)
3. SSH to IP with Ed25519 key + OS Login username
4. tmux auto-attaches, terminal is ready

### Data Flow
```
SwiftUI View
    ↓
SwiftTerm TerminalView (via Representable wrapper)
    ↕  feed(byteArray:) / send(data:)
Citadel SSHClient (PTY channel, xterm-256color)
    ↓
GCP VM (claude-dev-vm, ephemeral IP from Cloud Function)
```

- SwiftTerm provides terminal emulation (renders escape sequences, handles input)
- Citadel provides SSH connection with PTY support
- tmux works automatically — auto-attaches on SSH login
- SSH keys generated in-app, stored in Keychain, public key added to GCP via `gcloud compute os-login ssh-keys add`

## Build Phases

### Phase 1: Todos (validates full pipeline) — DONE (UX fixes remaining)
1. ~~Create Xcode multiplatform project with CloudKit entitlement~~
2. ~~Define TodoItem model, configure ModelContainer~~
3. ~~Build TodoListView, TodoRowView, TodoDetailView~~
4. ~~Implement NotificationManager for reminders~~
5. Test sync between iPhone and Mac via CloudKit (requires signing in Xcode)
6. Wire TodoRowView tap to TodoDetailView for editing (currently unreachable)
7. Add drag-to-reorder (`.onMove`) — sortOrder exists on model but isn't exposed
8. Add delete confirmation or undo support via `UndoManager`
9. Constrain reminder DatePicker to future dates (`in: Date()...`)
10. Add "Clear Completed" button in completed section header
11. Defer notification permission request to first reminder creation (not app launch)

**Notes:** Using XcodeGen (`project.yml`). Targets: iOS 18+, macOS 15+ (required for `Tab` API). User needs to set Development Team and enable iCloud capability in Xcode before testing sync.

### Phase 2: Notes
1. Add MarkdownUI dependency
2. Define Note model
3. Build NoteListView with search + pinning
4. Build editor/preview with toggle on iPhone; default to side-by-side on Mac (fall back to toggle when window is narrow)
5. Auto-save with debounce — write directly to SwiftData (not a temp buffer) to avoid data loss on app kill
6. Add macOS markdown keyboard shortcuts (Cmd+B, Cmd+I, etc.) — plan with the editor, not deferred to Phase 4

### Phase 3: Terminal
1. Add SwiftTerm + Citadel dependencies
2. Implement VMStarter — calls Cloud Function, parses IP, shows VM status
3. Implement SSHKeyManager (key gen + Keychain)
4. Build platform-specific Representable wrappers
5. Implement SSHConnectionManager (SSH ↔ SwiftTerm piping)
6. Build TerminalContainerView (VM start → SSH connect → terminal display)
7. Add VM startup progress UI with estimated wait time and cancel button (cold start takes 20-40s)
8. Implement reconnection UX: detect SSH drops (network switch, sleep/wake, iOS backgrounding), show disconnected state, auto-reconnect since tmux preserves the session
9. Add iOS keyboard accessory bar with Ctrl, Tab, Esc, arrow keys — terminal is unusable on iPhone without this
10. Add font size control (pinch-to-zoom or setting) — especially important on iPhone
11. One-time setup: generate key in app, add public key to GCP via `gcloud compute os-login ssh-keys add`
12. Test: tap Terminal tab → VM starts → SSH connects → tmux session visible, verify on both platforms

### Phase 4: Polish
- App icon, theming, error handling, macOS keyboard shortcuts
- Hide unimplemented tabs until their phase is complete (avoid "coming soon" placeholders)
- CloudKit sync conflict indication — surface merge issues to the user rather than silently dropping edits

## Security

### Cloud Function Authentication
The VM starter Cloud Function must not be publicly callable. Add authentication so only the Odin app can invoke it:
- Add IAM `roles/cloudfunctions.invoker` restricted to a service account or use Firebase Auth
- At minimum, require a secret API key in a request header and validate it in the function
- Add rate limiting to prevent abuse (e.g., max 5 starts per hour) to cap billing exposure

### SSH Host Key Verification
With an ephemeral VM IP, standard TOFU (trust-on-first-use) is insufficient:
- The Cloud Function should return the VM's SSH host key fingerprint alongside the IP
- The app must verify the host key on connect and reject mismatches
- This prevents MITM attacks where a spoofed IP is returned

### SSH Key Protection
Ed25519 keys in Keychain need proper access controls:
- Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to prevent iCloud Keychain sync of private keys
- Require biometric auth (Face ID / Touch ID) before releasing the private key via `SecAccessControlCreateWithFlags` with `.biometryCurrentSet`
- This prevents unauthorized terminal access on a stolen or unlocked device

### Data Sensitivity Boundaries
- **Keychain only**: SSH private keys (already planned — correct)
- **SwiftData + CloudKit**: Todos, notes, SSH host configs (hostname, port, username). Acceptable for a personal app, but be aware these sync to any device signed into the same iCloud account
- **Never persisted**: SSH session data, terminal output

## Verification

- **Phase 1**: Create todo on iPhone → appears on Mac within seconds. Set reminder → notification fires.
- **Phase 2**: Create note with markdown on Mac → renders correctly on iPhone. Edit on either device syncs.
- **Phase 3**: SSH to GCP VM, run `tmux attach`, verify colors/panes render. Test on both iPhone and Mac.
- **All phases**: Build and run on both iOS simulator and macOS target. Test on real devices for CloudKit sync.
