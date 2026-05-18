#if os(macOS)
import Foundation

/// Installs a `UserPromptSubmit` hook that drains the per-session pending file
/// at `~/.claude/odin-pending/<ODIN_SESSION_ID>.txt`. The hook's stdout is
/// prepended to the next assistant turn's context, so Claude learns about
/// completed background tasks at the earliest natural moment without polling.
///
/// Two pieces:
///   1. `~/.claude/hooks/odin-pending.sh` — the drain script (always rewritten).
///   2. An entry in `~/.claude/settings.json` under `hooks.UserPromptSubmit`.
///      Merged idempotently: existing entries are preserved.
enum OdinHookInstaller {
    static func install() {
        installScript()
        registerInSettings()
    }

    private static var scriptPath: String {
        NSHomeDirectory() + "/.claude/hooks/odin-pending.sh"
    }

    private static let scriptBody = #"""
    #!/usr/bin/env bash
    # Auto-installed by Odin. Drains pending background-task completions for
    # the current Odin-spawned Claude session and prints them to stdout so
    # Claude Code injects them into the next assistant turn.
    set -e
    [[ -n "$ODIN_SESSION_ID" ]] || exit 0
    PENDING="$HOME/.claude/odin-pending/$ODIN_SESSION_ID.txt"
    [[ -f "$PENDING" ]] || exit 0
    cat "$PENDING"
    rm -f "$PENDING"
    """#

    private static func installScript() {
        let dir = NSHomeDirectory() + "/.claude/hooks"
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
            try scriptBody.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptPath
            )
            NSLog("[OdinHook] installed script at \(scriptPath)")
        } catch {
            NSLog("[OdinHook] failed to install script: \(error)")
        }
    }

    private static func registerInSettings() {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var root: [String: Any] = [:]

        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []

        // Idempotency: skip if any existing entry's nested command points at
        // our script (regardless of nesting style).
        if entries.contains(where: { entryReferencesOurScript($0) }) {
            return
        }

        let ourEntry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": scriptPath
                ]
            ]
        ]
        entries.append(ourEntry)
        hooks["UserPromptSubmit"] = entries
        root["hooks"] = hooks

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try out.write(to: URL(fileURLWithPath: settingsPath))
            NSLog("[OdinHook] registered UserPromptSubmit hook → \(scriptPath)")
        } catch {
            NSLog("[OdinHook] failed to update settings.json: \(error)")
        }
    }

    private static func entryReferencesOurScript(_ entry: [String: Any]) -> Bool {
        // Flat form: {"type": "command", "command": "<path>"}
        if let cmd = entry["command"] as? String, cmd == scriptPath {
            return true
        }
        // Nested form: {"hooks": [{"type": "command", "command": "<path>"}]}
        if let inner = entry["hooks"] as? [[String: Any]] {
            return inner.contains { ($0["command"] as? String) == scriptPath }
        }
        return false
    }
}
#endif
