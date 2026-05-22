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

    /// Validate the user-supplied name with an allow-list. The name becomes
    /// both a git branch ref (`-b <name>`) and a path component
    /// (`<base>--<name>`), so the safer default is "only characters we know
    /// are fine in both contexts". Process arguments go directly to git
    /// (no shell), so shell metacharacters can't escape — this is robustness,
    /// not injection defence.
    static func validate(name: String) throws {
        if name.isEmpty {
            throw WorktreeError.invalidName("name is empty")
        }
        // Must start with an alphanumeric (rules out leading `-`, `.`, `/`,
        // and the noisy set of git-special prefixes), then up to 127 more
        // chars from a conservative set: alphanumerics, `.`, `_`, `-`, `/`.
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"#
        if name.range(of: pattern, options: .regularExpression) == nil {
            throw WorktreeError.invalidName(
                "must start with a letter or digit; allowed chars: A-Z a-z 0-9 . _ - /"
            )
        }
        if name.contains("..") {
            throw WorktreeError.invalidName("name can't contain '..'")
        }
    }

    static func create(sourcePath: String, name: String) async throws -> String {
        try validate(name: name)

        let probe = await GitCommand.run(["rev-parse", "--git-dir"], cwd: sourcePath)
        guard probe.exitCode == 0 else {
            throw WorktreeError.notAGitRepo(sourcePath)
        }

        let target = proposedWorktreePath(sourcePath: sourcePath, name: name)
        if FileManager.default.fileExists(atPath: target) {
            throw WorktreeError.targetExists(target)
        }

        let fetch = await GitCommand.run(["fetch", "origin"], cwd: sourcePath)
        guard fetch.exitCode == 0 else {
            let message = fetch.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.fetchFailed(message.isEmpty ? "exit \(fetch.exitCode)" : message)
        }

        let startPoint = try await resolveDefaultStartPoint(cwd: sourcePath)

        // `--` ends option parsing so a hypothetical future change that lets a
        // `-`-prefixed value slip through doesn't get treated as a flag.
        let result = await GitCommand.run(
            ["worktree", "add", "-b", name, "--", target, startPoint],
            cwd: sourcePath
        )
        guard result.exitCode == 0 else {
            let message = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "exit \(result.exitCode)" : message)
        }
        return target
    }

    /// Returns the fully-qualified remote ref to branch from — typically
    /// `origin/main`, but resolved dynamically so repos using `master`,
    /// `develop`, or anything else still work.
    private static func resolveDefaultStartPoint(cwd: String) async throws -> String {
        let symbolic = await GitCommand.run(
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            cwd: cwd
        )
        if symbolic.exitCode == 0 {
            let value = symbolic.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        // `origin/HEAD` may be unset on older clones; ask the remote directly.
        let remoteShow = await GitCommand.run(["remote", "show", "origin"], cwd: cwd)
        if remoteShow.exitCode == 0 {
            let prefix = "HEAD branch:"
            for line in remoteShow.combined.split(separator: "\n") {
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
    /// a submodule, or any non-git folder — i.e. "nothing to prompt about
    /// on removal". Detection is filesystem-only (no `git` subprocess): a
    /// linked worktree's `.git` is a regular file whose single
    /// `gitdir: <main>/.git/worktrees/<name>` line points back at the main
    /// repo. Submodules use the same scheme with `.git/modules/<name>`, so
    /// we reject anything whose gitdir parent isn't `worktrees`.
    static func mainWorktreePath(for path: String) -> String? {
        let gitFile = URL(fileURLWithPath: path).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitFile.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return nil
        }
        guard let contents = try? String(contentsOf: gitFile, encoding: .utf8) else {
            return nil
        }
        var gitdir: String?
        for raw in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("gitdir:") else { continue }
            gitdir = String(line.dropFirst("gitdir:".count))
                .trimmingCharacters(in: .whitespaces)
            break
        }
        guard let raw = gitdir, !raw.isEmpty else { return nil }
        // git writes the gitdir relative to the worktree directory itself.
        let resolved: URL = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: path).appendingPathComponent(raw)
        let standardized = resolved.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        guard parent.lastPathComponent == "worktrees" else { return nil }
        // …/<main>/.git/worktrees/<name> → strip `worktrees` and `.git`.
        return parent.deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Deletes a linked worktree by running `git worktree remove --force` from
    /// the main worktree. `--force` is intentional: the branch and any commits
    /// stay in the main repo's refs, so the only thing at risk is uncommitted
    /// changes — which the caller is expected to have warned the user about.
    static func removeWorktree(target: String, mainPath: String) async throws {
        let result = await GitCommand.run(["worktree", "remove", "--force", "--", target], cwd: mainPath)
        guard result.exitCode == 0 else {
            let message = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "exit \(result.exitCode)" : message)
        }
    }

}
#endif
