#if os(macOS)
import Foundation

/// Shared helper for spawning `git` from the Claude feature's services.
/// Replaces three near-identical `runGit` implementations in
/// `WorktreeService`, `DiffService`, and `ProjectService`. Runs the process
/// on `DispatchQueue.global(qos: .userInitiated)` via `withCheckedContinuation`
/// so callers can `await` it without blocking the main actor.
///
/// Args are passed via `Process.arguments`, not a shell — so callers don't
/// need to quote/escape paths.
enum GitCommand {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32

        /// Stdout immediately followed by stderr. Matches the historic
        /// behaviour of the various `runGit` helpers that pointed both
        /// pipes at the same buffer.
        var combined: String { stdout + stderr }
    }

    static func run(_ args: [String], cwd: String) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["git"] + args
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    // Drain pipes before waitUntilExit() so a chatty git
                    // command can't fill the 64 KB pipe buffer and deadlock
                    // waiting for us to read.
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: Result(
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "",
                        exitCode: proc.terminationStatus
                    ))
                } catch {
                    cont.resume(returning: Result(
                        stdout: "",
                        stderr: "\(error)",
                        exitCode: -1
                    ))
                }
            }
        }
    }
}
#endif
