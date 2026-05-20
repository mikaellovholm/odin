#if os(macOS)
import Foundation

enum WorktreeError: LocalizedError {
    case notAGitRepo(String)
    case targetExists(String)
    case invalidName(String)
    case fetchFailed(String)
    case defaultBranchUnknown
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepo(let path):
            return "\(path) is not a git repository."
        case .targetExists(let path):
            return "A folder already exists at:\n\(path)"
        case .invalidName(let reason):
            return "Invalid worktree name: \(reason)"
        case .fetchFailed(let message):
            return "git fetch origin failed:\n\(message)"
        case .defaultBranchUnknown:
            return "Couldn't determine origin's default branch. Make sure the repo has an `origin` remote with a HEAD set."
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

        let fetch = await runGit(["fetch", "origin"], cwd: sourcePath)
        guard fetch.exitCode == 0 else {
            let message = fetch.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.fetchFailed(message.isEmpty ? "exit \(fetch.exitCode)" : message)
        }

        let startPoint = try await resolveDefaultStartPoint(cwd: sourcePath)

        // `--` ends option parsing so a hypothetical future change that lets a
        // `-`-prefixed value slip through doesn't get treated as a flag.
        let result = await runGit(
            ["worktree", "add", "-b", name, "--", target, startPoint],
            cwd: sourcePath
        )
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "exit \(result.exitCode)" : message)
        }
        return target
    }

    /// Returns the fully-qualified remote ref to branch from — typically
    /// `origin/main`, but resolved dynamically so repos using `master`,
    /// `develop`, or anything else still work.
    private static func resolveDefaultStartPoint(cwd: String) async throws -> String {
        let symbolic = await runGit(
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            cwd: cwd
        )
        if symbolic.exitCode == 0 {
            let value = symbolic.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        // `origin/HEAD` may be unset on older clones; ask the remote directly.
        let remoteShow = await runGit(["remote", "show", "origin"], cwd: cwd)
        if remoteShow.exitCode == 0 {
            let prefix = "HEAD branch:"
            for line in remoteShow.output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(prefix) else { continue }
                let branch = trimmed
                    .dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespaces)
                // `git remote show origin` prints `HEAD branch: (unknown)` when
                // the remote has no default; treat that as "couldn't resolve"
                // rather than handing `origin/(unknown)` to git.
                if !branch.isEmpty && branch != "(unknown)" {
                    return "origin/\(branch)"
                }
            }
        }
        throw WorktreeError.defaultBranchUnknown
    }

    /// If `path` is a linked worktree, returns the main worktree's path.
    /// Returns `nil` for the main worktree itself, a non-worktree git repo,
    /// or any non-git folder — i.e. "nothing to prompt about on removal".
    static func mainWorktreePath(for path: String) async -> String? {
        let common = await runGit(["rev-parse", "--git-common-dir"], cwd: path)
        let gitDir = await runGit(["rev-parse", "--git-dir"], cwd: path)
        guard common.exitCode == 0, gitDir.exitCode == 0 else { return nil }
        let absCommon = absolutize(common.output, relativeTo: path)
        let absDir = absolutize(gitDir.output, relativeTo: path)
        // Main worktree: --git-dir and --git-common-dir resolve to the same
        // place. Linked worktree: --git-dir points inside the main repo's
        // `.git/worktrees/<name>`, --git-common-dir points at the main `.git`.
        if absCommon == absDir { return nil }
        return URL(fileURLWithPath: absCommon).deletingLastPathComponent().path
    }

    /// Deletes a linked worktree by running `git worktree remove --force` from
    /// the main worktree. `--force` is intentional: the branch and any commits
    /// stay in the main repo's refs, so the only thing at risk is uncommitted
    /// changes — which the caller is expected to have warned the user about.
    static func removeWorktree(target: String, mainPath: String) async throws {
        let result = await runGit(["worktree", "remove", "--force", "--", target], cwd: mainPath)
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "exit \(result.exitCode)" : message)
        }
    }

    private static func absolutize(_ raw: String, relativeTo cwd: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return trimmed }
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
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
