#if os(macOS)
import Foundation

enum ClaudePath {
    // Cached after the first call. Both successful and failed lookups are
    // cached so the expensive zsh shell-out only ever runs once per launch.
    // All callers run on @MainActor, so no locking is needed.
    private static var _resolved = false
    private static var _cachedPath: String? = nil

    static func resolve() -> String? {
        if _resolved { return _cachedPath }
        _resolved = true
        _cachedPath = _freshResolve()
        return _cachedPath
    }

    private static func _freshResolve() -> String? {
        let knownPaths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }
}
#endif
