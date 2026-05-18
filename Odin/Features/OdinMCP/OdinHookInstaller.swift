#if os(macOS)
import Foundation

/// Installs Claude Code hook scripts and registers them in
/// `~/.claude/settings.json`.
///
/// Two hook scripts are managed here:
///   1. `~/.claude/hooks/odin-pending.sh` — drains the per-session pending file
///      under `UserPromptSubmit`. Its stdout is injected into Claude's next
///      assistant turn so Claude learns about completed background tasks.
///   2. `~/.claude/hooks/odin-status.sh <state>` — writes the current Claude
///      lifecycle state to `~/.claude/odin-status/<ODIN_SESSION_ID>.state`.
///      Registered for `UserPromptSubmit` (working), `Stop` (idle),
///      `Notification` (awaiting-input), `SessionEnd` (delete). The Odin app
///      watches the state file to drive the sidebar status dot — far more
///      reliable than parsing the spinner braille char from the terminal title.
///
/// `settings.json` entries are merged idempotently; existing entries are
/// preserved.
enum OdinHookInstaller {
    static func install() {
        installScripts()
        registerInSettings()
    }

    // MARK: - Script paths

    private static var pendingScriptPath: String {
        NSHomeDirectory() + "/.claude/hooks/odin-pending.sh"
    }

    private static var statusScriptPath: String {
        NSHomeDirectory() + "/.claude/hooks/odin-status.sh"
    }

    // MARK: - Script bodies

    private static let pendingScriptBody = #"""
    #!/usr/bin/env bash
    # Auto-installed by Odin. Drains pending background-task completions for
    # the current Odin-spawned Claude session and prints them to stdout so
    # Claude Code injects them into the next assistant turn.
    set -e
    [[ -n "$ODIN_SESSION_ID" ]] || exit 0
    PENDING="$HOME/.claude/odin-pending/$ODIN_SESSION_ID.txt"
    [[ -f "$PENDING" ]] || exit 0
    # Atomically claim the file with rename before reading so that a concurrent
    # completion notification appended between cat and rm can't be silently lost.
    TMP=$(mktemp)
    if mv "$PENDING" "$TMP" 2>/dev/null; then
        cat "$TMP"
        rm -f "$TMP"
    fi
    """#

    private static let statusScriptBody = #"""
    #!/usr/bin/env bash
    # Auto-installed by Odin. Writes the current Claude lifecycle state to a
    # per-session file the Odin app watches for sidebar indicator updates.
    # Driven by Claude Code lifecycle hooks (UserPromptSubmit/Stop/Notification/
    # SessionEnd) passing a state name as the first argument.
    set -e
    [[ -n "$ODIN_SESSION_ID" ]] || exit 0
    STATE="${1:-}"
    [[ -n "$STATE" ]] || exit 0
    DIR="$HOME/.claude/odin-status"
    mkdir -p "$DIR"
    FILE="$DIR/$ODIN_SESSION_ID.state"
    case "$STATE" in
        working|idle|awaiting-input)
            printf '%s\n' "$STATE" > "$FILE"
            ;;
        delete)
            rm -f "$FILE"
            ;;
    esac
    """#

    // MARK: - Install

    private static func installScripts() {
        installScript(at: pendingScriptPath, body: pendingScriptBody, name: "odin-pending")
        installScript(at: statusScriptPath, body: statusScriptBody, name: "odin-status")
    }

    private static func installScript(at path: String, body: String, name: String) {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: path
            )
            NSLog("[OdinHook] installed \(name) script at \(path)")
        } catch {
            NSLog("[OdinHook] failed to install \(name) script: \(error)")
        }
    }

    // MARK: - Settings registration

    /// Maps Claude Code hook event names to the command (script + args) we
    /// want registered under each.
    private static var hookRegistrations: [(event: String, command: String)] {
        [
            ("UserPromptSubmit", pendingScriptPath),
            ("UserPromptSubmit", "\(statusScriptPath) working"),
            ("Stop", "\(statusScriptPath) idle"),
            ("Notification", "\(statusScriptPath) awaiting-input"),
            ("SessionEnd", "\(statusScriptPath) delete"),
        ]
    }

    private static func registerInSettings() {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var root: [String: Any] = [:]

        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for (event, command) in hookRegistrations {
            if upsertHookEntry(hooks: &hooks, event: event, command: command) {
                changed = true
            }
        }

        guard changed else { return }
        root["hooks"] = hooks

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            // Atomic write so a crash mid-write can't leave settings.json
            // truncated or empty.
            try out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            NSLog("[OdinHook] updated settings.json with hook registrations")
        } catch {
            NSLog("[OdinHook] failed to update settings.json: \(error)")
        }
    }

    /// Appends an entry under the given event if no existing entry already
    /// references this exact command string. Returns true on mutation.
    private static func upsertHookEntry(
        hooks: inout [String: Any],
        event: String,
        command: String
    ) -> Bool {
        var entries = hooks[event] as? [[String: Any]] ?? []
        if entries.contains(where: { entryReferencesCommand($0, command: command) }) {
            return false
        }
        entries.append([
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ])
        hooks[event] = entries
        return true
    }

    private static func entryReferencesCommand(
        _ entry: [String: Any],
        command: String
    ) -> Bool {
        // Flat form: {"type": "command", "command": "<cmd>"}
        if let cmd = entry["command"] as? String, cmd == command {
            return true
        }
        // Nested form: {"hooks": [{"type": "command", "command": "<cmd>"}]}
        if let inner = entry["hooks"] as? [[String: Any]] {
            return inner.contains { ($0["command"] as? String) == command }
        }
        return false
    }
}
#endif
