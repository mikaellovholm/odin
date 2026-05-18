# Multiple Claude Sessions — Implementation Plan

> **Status (post-implementation):** Built as planned, then pivoted to an
> embedded layout. Each session no longer opens in its own `NSWindow` — the
> Claude tab is an `HSplitView` (sidebar + detail) and the selected session's
> terminal renders in the detail pane. `ClaudeSessionWindowController` was
> deleted; `ClaudeSessionWindowContent.swift` was renamed
> `ClaudeSessionDetailView.swift`. ⌘1…⌘9 shortcuts were added for the first
> nine sessions. See `CLAUDE.md` (Claude Terminal Feature) for the current
> shape.

## Goal

Let the user run several Claude Code sessions in parallel — one per working
directory (typically one per repo). The Claude tab becomes a session list; each
running session lives in its own macOS window.

macOS-only feature. iOS is unaffected (the existing `#if os(macOS)` guards stay
in place).

## UX Summary

- **Claude tab** shows a list of sessions instead of a terminal. The terminal
  no longer renders inside the tab itself.
- **"+" button** at the top of the list. Clicking it opens an `NSOpenPanel`
  immediately. If the user picks a folder, a new session is created and its
  window opens with Claude already starting. Cancel = no-op.
- **Each row** shows the folder's last path component (duplicates allowed) and
  a per-session activity indicator: `⬤` while Claude is working, `✓` if it
  just finished, nothing otherwise. The indicator is driven by the same OSC 0
  title heuristic that `LocalTerminalViewModel.handleTitleChanged` already
  uses.
- **Clicking a row** opens or focuses that session's window. If the window was
  closed (red traffic light) the Claude process kept running in the background
  and reopening attaches a fresh terminal view to it. Scrollback before the
  close is lost (acceptable for v1).
- **Right-click a row → Remove** terminates Claude, closes the window if open,
  and removes the session from the list. Closing a window alone does *not*
  remove the session.
- **Persistence**: the list of session directories survives app relaunch.
  Sessions come back in `notStarted` state — the user clicks the row to start
  Claude in that directory. Running processes don't survive app quit.

```
┌─────────────────────────────────┐    ┌────────────────────────┐
│ Claude  [+]                     │    │ ~/projects/odin        │
│ ─────────────────────────────── │    │                        │
│  odin               ⬤           │    │   $ claude             │
│  drumstick2          ✓           │    │   …                    │
│  conductor-bot                  │    │                        │
│                                 │    │                        │
└─────────────────────────────────┘    └────────────────────────┘
        Claude tab                       Per-session window
```

## Architecture

### New types

**`ClaudeSession`** (`Odin/Features/Claude/ClaudeSession.swift`)

```swift
@MainActor
@Observable
final class ClaudeSession: Identifiable {
    let id: UUID
    let workingDirectory: String      // absolute path
    var displayName: String           // (workingDirectory as NSString).lastPathComponent
    let viewModel: LocalTerminalViewModel
    var windowController: NSWindowController?   // nil when no window open

    init(workingDirectory: String, id: UUID = UUID())
}
```

The session owns the view model so the Claude process keeps running even when
the window is closed.

**`ClaudeSessionStore`** (`Odin/Features/Claude/ClaudeSessionStore.swift`)

```swift
@MainActor
@Observable
final class ClaudeSessionStore {
    private(set) var sessions: [ClaudeSession] = []

    func loadPersisted()                       // called on app launch
    func addSession(directory: String) -> ClaudeSession
    func remove(_ session: ClaudeSession)      // terminate + close window + persist
    func openWindow(for session: ClaudeSession) // create-or-focus
    private func persist()                     // UserDefaults: [String] of paths
}
```

One instance lives on `OdinApp` and is injected via `@Environment`.

**`ClaudeSessionWindowController`** (same file or sibling)

```swift
@MainActor
final class ClaudeSessionWindowController: NSWindowController, NSWindowDelegate {
    let session: ClaudeSession

    init(session: ClaudeSession)
    // windowShouldClose: returns true; window release-on-close is false so
    // the controller can re-show the same window later. Or we recreate the
    // window on each open and accept that scrollback is lost — simpler, picks
    // the same behaviour we already accept.
}
```

The window hosts a `ClaudeSessionWindowContent` SwiftUI view (replaces the
current `ClaudeTerminalContainerView` body) via `NSHostingController`.

**`ClaudeSessionListView`** (`Odin/Features/Claude/ClaudeSessionListView.swift`)

The new Claude tab content. Header with `+` button, `List` of `ClaudeSession`,
context menu on each row.

### Modified types

**`LocalTerminalViewModel`**

- Add `.notStarted` to the `State` enum (for restored-but-not-yet-launched
  sessions). Default state becomes `.notStarted` instead of `.starting`.
- No other changes — multiple instances are already safe; the singleton
  assumption was on the caller side, not inside the view model.

**`ContentView.swift`**

```swift
#if os(macOS)
@Environment(ClaudeSessionStore.self) private var sessionStore
#endif
```

Replace the existing `Tab(value: .claude)` body with `ClaudeSessionListView()`.
Aggregate badge logic on the tab label changes to:

- `⬤` if `sessionStore.sessions.contains(where: { $0.viewModel.isActive })`
- `✓` if any session recently went active → inactive (track on store)
- otherwise just "Claude"

`claudeViewModel` and `claudeFinished` `@State` properties are removed.

**`OdinApp.swift`**

```swift
#if os(macOS)
@State private var claudeSessionStore = ClaudeSessionStore()
#endif

WindowGroup { ContentView().environment(claudeSessionStore) }
    .onAppear { claudeSessionStore.loadPersisted() }
```

(Use `.task` on `ContentView` if `onAppear` on `WindowGroup` is awkward.)

**`ClaudeTerminalContainerView.swift`**

Renamed/repurposed as `ClaudeSessionWindowContent.swift`. Same internal logic
(directory picker overlay, state overlay, terminal representable) but bound to
a `ClaudeSession` instead of receiving a bare view model. The directory picker
overlay can be removed — by the time the window opens, the directory is known
and Claude starts automatically.

## File-by-file plan

```
Odin/Features/Claude/
  ClaudeSession.swift              NEW
  ClaudeSessionStore.swift         NEW (+ ClaudeSessionWindowController)
  ClaudeSessionListView.swift      NEW
  ClaudeSessionRow.swift           NEW (row with name + activity badge)
  ClaudeSessionWindowContent.swift RENAMED from ClaudeTerminalContainerView.swift,
                                   stripped of directory picker
  LocalTerminalViewModel.swift     MODIFIED (.notStarted state; default state)

Odin/
  ContentView.swift                MODIFIED (use store; new Claude tab body)
  OdinApp.swift                    MODIFIED (own & load the store)

project.yml                        no changes (XcodeGen picks up new files
                                   under Odin/ automatically)
```

## Window lifecycle

1. **Open** — `store.openWindow(for: session)`:
   - If `session.windowController` is non-nil and its window is visible →
     `makeKeyAndOrderFront(nil)`.
   - Else create `ClaudeSessionWindowController(session: session)`,
     wrap `ClaudeSessionWindowContent(session: session)` in
     `NSHostingController`, set as `contentViewController`. Configure window:
     title = `session.displayName`, frame autosave name keyed by session id,
     `isReleasedWhenClosed = false`. Store the controller on the session.
   - If `session.viewModel.state == .notStarted`, call `viewModel.startClaude()`.
2. **Close (red button)** — handled by the window's default close behavior;
   because `isReleasedWhenClosed = false` we can re-show later. The view model
   stays in the session, so the process keeps running. Window controller stays
   on the session for fast reopen.
3. **Remove (right-click → Remove)** — `store.remove(session)`:
   - Terminate the process: send SIGHUP via `LocalProcess` (add a small
     `terminate()` to `LocalTerminalViewModel`).
   - Close & release the window controller.
   - Drop the session from `sessions` and call `persist()`.
4. **App quit** — OS terminates child processes. Nothing special to do beyond
   persisting the directory list (which already happened on every mutation).

## Persistence

UserDefaults, single key `"claude.sessionDirectories"`, stored as
`[String]` (ordered list of absolute paths). Trivial; no Codable needed.

- `loadPersisted()` reads the array and creates a `ClaudeSession` for each
  path, with view model in `.notStarted`.
- `addSession` / `remove` append/remove and immediately persist.
- Reordering (drag to reorder rows in the list) is out of scope for v1 — easy
  to add later by re-persisting the array.

## Edge cases & notes

- **Folder no longer exists at load time**: keep the session in the list so the
  user can see it; starting Claude will fail and surface via the existing
  `.error` state in `LocalTerminalViewModel`. No automatic pruning.
- **Same directory twice**: allowed (user might intentionally want it).
- **`claude` binary missing**: already handled by `resolveClaudePath()`. The
  per-session window will show the error overlay.
- **Activity badge "finished" indicator (`✓`)**: store a per-session
  `didFinishSinceLastView: Bool` on `ClaudeSession`. Set when `isActive` goes
  `true → false`; clear when the window becomes key (`windowDidBecomeKey`).
  Same shape as the current `claudeFinished` flag, just per-session.
- **Tab badge aggregation**: derive from `sessions` directly; no separate
  state needed.

## Implementation order

1. Introduce `.notStarted` to `LocalTerminalViewModel.State`; default to it.
2. Create `ClaudeSession` and `ClaudeSessionStore` (without window logic yet);
   wire persistence; add the store to `OdinApp` env.
3. Build `ClaudeSessionListView` + `ClaudeSessionRow`. Replace Claude tab body
   in `ContentView`. At this point clicking a row does nothing useful, but the
   list, `+`, and remove work and persist.
4. Add `ClaudeSessionWindowController` + `ClaudeSessionWindowContent`. Wire
   `store.openWindow(for:)` from the `+` flow and from row clicks. Start
   Claude on first open.
5. Wire the per-row activity badge and the aggregate tab badge.
6. Manual test pass: create two sessions in different repos, confirm they run
   independently, close + reopen one window (process survives), remove a
   session (process dies), quit & relaunch (sessions restored as
   `.notStarted`).

## Out of scope (could come later)

- Reorder rows by drag.
- Rename a session (override `displayName`).
- Restore scrollback when a closed window is reopened.
- Auto-start persisted sessions on launch.
- iOS support — the SSH-based Terminal tab covers the iOS use case.
