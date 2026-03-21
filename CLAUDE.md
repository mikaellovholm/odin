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
`ContentView.swift` is a `TabView` with three tabs (Todos, Notes, Terminal). Each tab maps to an independent feature module under `Odin/Features/`.

### Feature Modules
Each feature lives in `Odin/Features/<Name>/` with its own views and services. Models live in `Odin/Models/`. Currently only Todos is implemented (Phase 1 complete). Notes (Phase 2) and Terminal/SSH (Phase 3) are planned — see `PLAN.md` for full details.

### Key Patterns
- `@Query` for reactive SwiftData fetching in list views
- `@Bindable` for mutating model properties in child views
- Sheet presentation for create/edit flows
- `NotificationManager` singleton wraps `UNUserNotificationCenter` for reminder scheduling

### Terminal Feature (Phase 3, not yet built)
Will use SwiftTerm (terminal emulation) + Citadel (SSH) to connect to a GCP VM. The VM has an ephemeral IP obtained via a Cloud Function. SSH keys are stored in Keychain, not SwiftData. Platform-specific `UIViewRepresentable`/`NSViewRepresentable` wrappers will be needed under `Odin/Platform/`.

## Platform Considerations

- Single codebase targets both iOS and macOS via `platform: [iOS, macOS]` in `project.yml`
- XcodeGen produces two schemes: `Odin_iOS` and `Odin_macOS`
- Code signing requires manually setting Development Team in Xcode; CloudKit sync requires the iCloud capability enabled
