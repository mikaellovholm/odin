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

### Phase 1: Todos (validates full pipeline)
1. Create Xcode multiplatform project with CloudKit entitlement
2. Define TodoItem model, configure ModelContainer
3. Build TodoListView, TodoRowView, TodoDetailView
4. Implement NotificationManager for reminders
5. Test sync between iPhone and Mac via CloudKit

### Phase 2: Notes
1. Add MarkdownUI dependency
2. Define Note model
3. Build NoteListView with search + pinning
4. Build editor/preview with toggle (side-by-side on Mac if wide)
5. Auto-save with debounce

### Phase 3: Terminal
1. Add SwiftTerm + Citadel dependencies
2. Implement VMStarter — calls Cloud Function, parses IP, shows VM status
3. Implement SSHKeyManager (key gen + Keychain)
4. Build platform-specific Representable wrappers
5. Implement SSHConnectionManager (SSH ↔ SwiftTerm piping)
6. Build TerminalContainerView (VM start → SSH connect → terminal display)
7. One-time setup: generate key in app, add public key to GCP via `gcloud compute os-login ssh-keys add`
8. Test: tap Terminal tab → VM starts → SSH connects → tmux session visible, verify on both platforms

### Phase 4: Polish
- App icon, theming, error handling, macOS keyboard shortcuts, empty states

## Verification

- **Phase 1**: Create todo on iPhone → appears on Mac within seconds. Set reminder → notification fires.
- **Phase 2**: Create note with markdown on Mac → renders correctly on iPhone. Edit on either device syncs.
- **Phase 3**: SSH to GCP VM, run `tmux attach`, verify colors/panes render. Test on both iPhone and Mac.
- **All phases**: Build and run on both iOS simulator and macOS target. Test on real devices for CloudKit sync.
