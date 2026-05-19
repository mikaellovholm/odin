#if os(macOS)
import Foundation

enum DiffServiceError: LocalizedError {
    case notAGitRepo(String)
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepo(let path):
            return "\(path) is not a git repository."
        case .gitFailed(let msg):
            return "git failed: \(msg)"
        }
    }
}

/// Read-only git wrappers backing the diff side panel. All calls run on a
/// background queue so the UI thread never blocks on git.
enum DiffService {
    /// List of files changed in the working tree vs HEAD, plus untracked files.
    /// Renames, copies, and type changes are detected. Binary status is filled
    /// in from `--numstat` (numstat reports `-\t-` for binary).
    static func changedFiles(in cwd: String) async -> [ChangedFile] {
        // Use --porcelain=v1 -z for unambiguous parsing (NUL-separated, no quoting).
        let statusOut = await runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            cwd: cwd
        )
        guard statusOut.exitCode == 0 else { return [] }
        let entries = parsePorcelainV1Z(statusOut.output)
        guard !entries.isEmpty else { return [] }

        // Get +/- counts for tracked, non-deleted entries in one shot.
        let numstatOut = await runGit(
            ["diff", "--numstat", "-M", "HEAD"],
            cwd: cwd
        )
        let numstats = parseNumstat(numstatOut.output)

        var result: [ChangedFile] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            let stat = numstats[entry.path] ?? numstats[entry.oldPath ?? ""]
            let (additions, deletions, isBinary): (Int, Int, Bool) = {
                if let s = stat { return s }
                // Untracked: no numstat row exists. Count lines as additions.
                if entry.status == .untracked {
                    let full = (cwd as NSString).appendingPathComponent(entry.path)
                    let (lines, binary) = countLinesOrBinary(at: full)
                    return (lines, 0, binary)
                }
                return (0, 0, false)
            }()
            result.append(ChangedFile(
                path: entry.path,
                oldPath: entry.oldPath,
                status: entry.status,
                additions: additions,
                deletions: deletions,
                isBinary: isBinary
            ))
        }
        return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// Raw unified diff text for one file. Empty string means no textual diff
    /// (e.g. binary file, or file became identical between calls). Caller
    /// should already know whether the file is binary and skip this call.
    static func unifiedDiff(for file: ChangedFile, in cwd: String) async -> String {
        if file.isBinary { return "" }
        switch file.status {
        case .untracked:
            // Compare /dev/null to the working-tree path to render the whole
            // file as added lines. --no-index exits 1 on differences (expected).
            let r = await runGit(
                ["diff", "--no-color", "--no-index", "--", "/dev/null", file.path],
                cwd: cwd
            )
            return r.output
        case .deleted, .modified, .added, .renamed, .copied, .typeChanged, .unmerged:
            // -M turns on rename detection so the diff header matches the
            // status entry. The path arg uses the new name (git resolves the
            // rename internally).
            let r = await runGit(
                ["diff", "--no-color", "-M", "HEAD", "--", file.path],
                cwd: cwd
            )
            return r.output
        }
    }

    static func isGitRepo(_ cwd: String) async -> Bool {
        let r = await runGit(["rev-parse", "--git-dir"], cwd: cwd)
        return r.exitCode == 0
    }

    // MARK: - Parsing

    private struct StatusEntry {
        let status: ChangedFile.Status
        let path: String
        let oldPath: String?
    }

    /// `--porcelain=v1 -z` output: each entry is `XY <path>\0` (with `XY` two
    /// status chars and a space), except R/C which are `XY <new>\0<old>\0`.
    private static func parsePorcelainV1Z(_ raw: String) -> [StatusEntry] {
        var entries: [StatusEntry] = []
        // Split on NUL while preserving emptys; iterate manually since rename
        // entries consume two records.
        let parts = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // Drop the trailing empty produced by the final NUL.
        var iter = parts.makeIterator()
        while let rec = iter.next() {
            guard rec.count > 3 else { continue }
            let xy = String(rec.prefix(2))
            let path = String(rec.dropFirst(3)) // drop "XY "
            let primary = xy.first.map(String.init) ?? " "
            let secondary = xy.dropFirst().first.map(String.init) ?? " "

            let isRename = primary == "R" || secondary == "R"
            let isCopy = primary == "C" || secondary == "C"

            if isRename || isCopy {
                // Next record is the old name.
                guard let oldName = iter.next() else { continue }
                entries.append(StatusEntry(
                    status: isRename ? .renamed : .copied,
                    path: path,
                    oldPath: oldName
                ))
                continue
            }

            let status = mapPorcelainStatus(xy: xy)
            entries.append(StatusEntry(status: status, path: path, oldPath: nil))
        }
        return entries
    }

    private static func mapPorcelainStatus(xy: String) -> ChangedFile.Status {
        // Index column (xy[0]) takes precedence for staged work; worktree
        // column (xy[1]) for unstaged. Show the more "visible" change.
        if xy == "??" { return .untracked }
        if xy.contains("U") || xy == "DD" || xy == "AA" { return .unmerged }
        let chars = Array(xy)
        let candidates = [chars[0], chars[1]]
        if candidates.contains("D") { return .deleted }
        if candidates.contains("A") { return .added }
        if candidates.contains("M") { return .modified }
        if candidates.contains("T") { return .typeChanged }
        if candidates.contains("R") { return .renamed }
        if candidates.contains("C") { return .copied }
        return .modified
    }

    /// `git diff --numstat` rows look like `<adds>\t<dels>\t<path>` or
    /// `-\t-\t<path>` for binaries. Rename rows are `<adds>\t<dels>\t<old> => <new>`
    /// or with -z `<adds>\t<dels>\t\0<old>\0<new>\0`. We're not using -z here
    /// for numstat (one call, parsed by line) so rename entries split on " => ".
    private static func parseNumstat(_ raw: String) -> [String: (Int, Int, Bool)] {
        var map: [String: (Int, Int, Bool)] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let addStr = String(parts[0])
            let delStr = String(parts[1])
            var path = String(parts[2])
            let isBinary = addStr == "-" && delStr == "-"
            let adds = Int(addStr) ?? 0
            let dels = Int(delStr) ?? 0

            // Handle "old => new" rename rows. The "new" path is what status
            // reports too, so key the map on that.
            if let arrow = path.range(of: " => ") {
                path = String(path[arrow.upperBound...])
            }
            // Strip "{a => b}" style if present (occurs without -z when paths share a prefix).
            if let open = path.firstIndex(of: "{"),
               let close = path.firstIndex(of: "}"),
               let arrow = path.range(of: " => ", range: open..<close) {
                let prefix = path[..<open]
                let renamedTo = path[arrow.upperBound..<close]
                let suffix = path[path.index(after: close)...]
                path = String(prefix) + String(renamedTo) + String(suffix)
            }
            map[path] = (adds, dels, isBinary)
        }
        return map
    }

    /// Count newline-terminated lines in a file, returning (lines, isBinary).
    /// A NUL byte in the first 8 KB classifies the file as binary.
    private static func countLinesOrBinary(at path: String) -> (Int, Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (0, false) }
        defer { try? handle.close() }
        var lines = 0
        var sawNonNewlineByte = false
        var checkedBinary = false
        var totalBytesChecked = 0
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if !checkedBinary {
                let slice = chunk.prefix(8192 - totalBytesChecked)
                if slice.contains(0) { return (0, true) }
                totalBytesChecked += slice.count
                if totalBytesChecked >= 8192 { checkedBinary = true }
            }
            for b in chunk {
                if b == 0x0A {
                    lines += 1
                    sawNonNewlineByte = false
                } else {
                    sawNonNewlineByte = true
                }
            }
        }
        // Count a trailing line without newline.
        if sawNonNewlineByte { lines += 1 }
        return (lines, false)
    }

    // MARK: - Process

    private struct GitResult {
        let exitCode: Int32
        let output: String
    }

    private static func runGit(_ args: [String], cwd: String) async -> GitResult {
        await withCheckedContinuation { (cont: CheckedContinuation<GitResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["git"] + args
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let stdout = Pipe()
                let stderr = Pipe()
                proc.standardOutput = stdout
                proc.standardError = stderr
                do {
                    try proc.run()
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let combined = (String(data: outData, encoding: .utf8) ?? "")
                        + (String(data: errData, encoding: .utf8) ?? "")
                    cont.resume(returning: GitResult(
                        exitCode: proc.terminationStatus,
                        output: combined
                    ))
                } catch {
                    cont.resume(returning: GitResult(exitCode: -1, output: "\(error)"))
                }
            }
        }
    }
}
#endif
