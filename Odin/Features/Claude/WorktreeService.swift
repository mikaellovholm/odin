#if os(macOS)
import Foundation

enum WorktreeError: LocalizedError {
    case notAGitRepo(String)
    case targetExists(String)
    case invalidName(String)
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepo(let path):
            return "\(path) is not a git repository."
        case .targetExists(let path):
            return "A folder already exists at:\n\(path)"
        case .invalidName(let reason):
            return "Invalid worktree name: \(reason)"
        case .gitFailed(let message):
            return "git worktree failed:\n\(message)"
        }
    }
}

enum WorktreeService {
    /// Strip a `--<suffix>` from a folder name so worktrees of worktrees still
    /// produce a flat sibling layout (`odin--worktree` + `feature-x` → `odin--feature-x`).
    static func repoBaseName(for folderName: String) -> String {
        if let range = folderName.range(of: "--") {
            return String(folderName[..<range.lowerBound])
        }
        return folderName
    }

    static func proposedWorktreePath(sourcePath: String, name: String) -> String {
        let url = URL(fileURLWithPath: sourcePath)
        let parent = url.deletingLastPathComponent().path
        let base = repoBaseName(for: url.lastPathComponent)
        return "\(parent)/\(base)--\(name)"
    }

    /// Validate the user-supplied name. We're stricter than `git check-ref-format`
    /// because the name also becomes a path component (`<base>--<name>`), so we
    /// reject slashes and dots up front for a friendlier error than git's.
    static func validate(name: String) throws {
        if name.isEmpty {
            throw WorktreeError.invalidName("name is empty")
        }
        if name.hasPrefix("-") {
            throw WorktreeError.invalidName("name can't start with '-'")
        }
        let illegal: Set<Character> = ["/", "\\", " ", ":", "~", "^", "?", "*", "[", "]", "\0"]
        if name.contains(where: { illegal.contains($0) }) {
            throw WorktreeError.invalidName("name can't contain spaces or any of / \\ : ~ ^ ? * [ ]")
        }
        if name.contains("..") {
            throw WorktreeError.invalidName("name can't contain '..'")
        }
    }

    static func create(sourcePath: String, name: String) async throws -> String {
        try validate(name: name)

        let probe = await runGit(["rev-parse", "--git-dir"], cwd: sourcePath)
        guard probe.exitCode == 0 else {
            throw WorktreeError.notAGitRepo(sourcePath)
        }

        let target = proposedWorktreePath(sourcePath: sourcePath, name: name)
        if FileManager.default.fileExists(atPath: target) {
            throw WorktreeError.targetExists(target)
        }

        // `--` ends option parsing so a hypothetical future change that lets a
        // `-`-prefixed value slip through doesn't get treated as a flag.
        let result = await runGit(["worktree", "add", "-b", name, "--", target], cwd: sourcePath)
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "exit \(result.exitCode)" : message)
        }
        return target
    }

    private struct GitResult {
        let exitCode: Int32
        let output: String
    }

    private static func runGit(_ args: [String], cwd: String) async -> GitResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<GitResult, Never>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["git"] + args
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(
                        returning: GitResult(exitCode: proc.terminationStatus, output: output)
                    )
                } catch {
                    continuation.resume(
                        returning: GitResult(exitCode: -1, output: "\(error)")
                    )
                }
            }
        }
    }
}
#endif
