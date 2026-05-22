#if os(macOS)
import Foundation

enum ClaudePath {
    /// `@AppStorage` key for the Settings override. When set to a non-empty
    /// path that exists and is executable, it short-circuits the allow-list
    /// lookup — escape hatch for users whose `claude` lives somewhere we
    /// don't anticipate (custom prefix, version manager). Still bypasses the
    /// shell entirely, so a poisoned rc file can't sneak through.
    static let overrideKey = "claude.binaryPathOverride"

    /// Allow-list of known-good install locations. Public so Settings can
    /// show users where we'd look by default.
    static var knownPaths: [String] {
        [
            "\(NSHomeDirectory())/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
    }

    static func resolve() -> String? {
        // No caching: cheap (stat × 5) and the user can change the override
        // via Settings at any time. Caching would surprise them.
        if let override = UserDefaults.standard.string(forKey: overrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
#endif
