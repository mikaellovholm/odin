#if os(macOS)
import Foundation

enum PRViewError: LocalizedError {
    case ghNotFound
    case ghFailed(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "gh CLI not found. Install with `brew install gh`, then sign in with `gh auth login`."
        case .ghFailed(let message):
            return message.isEmpty ? "gh pr view --web failed." : message
        }
    }
}

enum PRViewService {
    private static let installDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        ("~/.local/bin" as NSString).expandingTildeInPath,
    ]

    static func openInBrowser(workingDirectory: String) async throws {
        guard let binary = resolveBinary() else {
            throw PRViewError.ghNotFound
        }
        let result = await run(binary: binary, args: ["pr", "view", "--web"], cwd: workingDirectory)
        guard result.exitCode == 0 else {
            let message = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PRViewError.ghFailed(message)
        }
    }

    private static func resolveBinary() -> String? {
        for dir in installDirs {
            let path = (dir as NSString).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private struct Result {
        let combined: String
        let exitCode: Int32
    }

    private static func run(binary: String, args: [String], cwd: String) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = args
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
                // gh shells out to git for branch/remote info; give it a PATH
                // that finds Apple's /usr/bin/git plus the common Homebrew dirs.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                proc.environment = env
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: Result(
                        combined: String(data: data, encoding: .utf8) ?? "",
                        exitCode: proc.terminationStatus
                    ))
                } catch {
                    cont.resume(returning: Result(combined: "\(error)", exitCode: -1))
                }
            }
        }
    }
}
#endif
