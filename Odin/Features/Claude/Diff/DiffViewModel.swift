#if os(macOS)
import Foundation

/// Per-session diff state. One instance lives on each `ClaudeSession` so the
/// file list and currently-loaded diff survive detail-view rebuilds when the
/// user switches sessions.
@MainActor
@Observable
final class DiffViewModel {
    let workingDirectory: String

    var isGitRepo: Bool = true
    var isLoading: Bool = false
    var errorMessage: String?

    var files: [ChangedFile] = []
    var selectedFileID: String?
    var selectedFile: ChangedFile? {
        guard let id = selectedFileID else { return nil }
        return files.first { $0.id == id }
    }

    /// Parsed hunks for the currently-selected file. Nil while loading or if
    /// no selection.
    var selectedDiff: [DiffHunk]?
    /// True iff we tried to load the selected file and got "binary".
    var selectedIsBinary: Bool = false
    /// True iff the parsed diff was clipped by the hard line cap.
    var selectedTruncated: Bool = false

    /// Render cap per file. Generated files (e.g. `*.pbxproj`) can be enormous;
    /// rendering 100k lines via SwiftUI LazyVStack still costs measurable
    /// memory and parse time.
    static let renderLineCap = 2_000

    private var watcher: WorktreeWatcher?
    /// Bumped on every `refresh` so stale async results can be ignored.
    private var refreshGeneration = 0
    /// Bumped on every `loadDiff` so a slow load for a since-deselected file
    /// can be discarded.
    private var loadGeneration = 0

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    /// Called when the diff pane appears. Starts the FSEvents watcher and
    /// kicks off an initial refresh.
    func activate() {
        if watcher == nil {
            watcher = WorktreeWatcher(path: workingDirectory) { [weak self] in
                self?.refresh()
            }
        }
        watcher?.start()
        refresh()
    }

    /// Called when the diff pane disappears. Stops the watcher so we don't
    /// keep an FSEvents stream open for hidden panes.
    func deactivate() {
        watcher?.stop()
    }

    func refresh() {
        refreshGeneration &+= 1
        let gen = refreshGeneration
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            let isRepo = await DiffService.isGitRepo(workingDirectory)
            guard gen == refreshGeneration else { return }
            if !isRepo {
                isGitRepo = false
                files = []
                selectedFileID = nil
                selectedDiff = nil
                isLoading = false
                return
            }
            isGitRepo = true
            let newFiles = await DiffService.changedFiles(in: workingDirectory)
            guard gen == refreshGeneration else { return }
            files = newFiles
            // Preserve selection if the file is still in the list; otherwise
            // pick the first file so the diff pane always shows something.
            if let id = selectedFileID, newFiles.contains(where: { $0.id == id }) {
                // Same file — reload its diff in case content changed.
                if let f = newFiles.first(where: { $0.id == id }) {
                    await loadDiff(for: f)
                }
            } else if let first = newFiles.first {
                selectedFileID = first.id
                await loadDiff(for: first)
            } else {
                selectedFileID = nil
                selectedDiff = nil
            }
            isLoading = false
        }
    }

    func select(_ file: ChangedFile) {
        guard file.id != selectedFileID else { return }
        selectedFileID = file.id
        selectedDiff = nil
        selectedIsBinary = false
        selectedTruncated = false
        Task { @MainActor in
            await loadDiff(for: file)
        }
    }

    private func loadDiff(for file: ChangedFile) async {
        loadGeneration &+= 1
        let gen = loadGeneration
        if file.isBinary {
            selectedDiff = []
            selectedIsBinary = true
            selectedTruncated = false
            return
        }
        let raw = await DiffService.unifiedDiff(for: file, in: workingDirectory)
        guard gen == loadGeneration, file.id == selectedFileID else { return }
        var hunks = UnifiedDiffParser.parse(raw)
        // Cap by total rendered lines across all hunks.
        var total = 0
        var truncated = false
        var capped: [DiffHunk] = []
        for hunk in hunks {
            if total + hunk.lines.count <= Self.renderLineCap {
                capped.append(hunk)
                total += hunk.lines.count
                continue
            }
            let remaining = Self.renderLineCap - total
            if remaining > 0 {
                capped.append(DiffHunk(
                    id: hunk.id,
                    header: hunk.header,
                    oldStart: hunk.oldStart,
                    newStart: hunk.newStart,
                    lines: Array(hunk.lines.prefix(remaining))
                ))
            }
            truncated = true
            break
        }
        hunks = capped
        selectedDiff = hunks
        selectedIsBinary = false
        selectedTruncated = truncated
    }
}
#endif
