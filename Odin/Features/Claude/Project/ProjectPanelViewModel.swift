#if os(macOS)
import Foundation

/// Per-session state for the project side panel. One instance lives on each
/// `ClaudeSession` so the tree, expanded set, and currently-open file survive
/// detail-view rebuilds when the user switches sessions (same pattern as
/// `viewModel` / `diffViewModel` / `shellViewModel`).
@MainActor
@Observable
final class ProjectPanelViewModel {
    let workingDirectory: String

    var rootNode: ProjectFileNode?
    var isGitRepo: Bool = true
    var isLoading: Bool = false
    var treeTruncated: Bool = false
    var errorMessage: String?

    /// Set of directory URLs the user has expanded. Persisted in-memory only.
    var expandedURLs: Set<URL> = []

    /// Currently-open file. Nil means the file viewer column collapses.
    var selectedFileURL: URL?
    var selectedFileContent: String?
    var selectedFileIsBinary: Bool = false
    var selectedFileTruncated: Bool = false
    var selectedFileLanguage: String?
    var selectedFileIsLoading: Bool = false

    /// Keyboard-cursor row in the tree. Independent of `selectedFileURL`
    /// (selection = the file currently open in the viewer). The arrow keys
    /// move `focusedNodeURL`; Enter on a file commits it as selection.
    var focusedNodeURL: URL?

    /// Which sub-pane should currently own keyboard focus. The two views
    /// (`ProjectPanelView`, `FileViewerView`) each observe
    /// `focusGeneration` and re-assert their `@FocusState` when the target
    /// matches them. The counter is necessary because re-asserting the same
    /// target after the user clicks away has to still re-grab focus.
    enum FocusTarget { case tree, viewer }
    var focusTarget: FocusTarget = .tree
    var focusGeneration: Int = 0

    /// Bumped on every `reload` so stale tree loads can be ignored.
    private var loadGeneration = 0
    /// Bumped on every file `select` so a slow load for a since-deselected file
    /// can be discarded.
    private var fileLoadGeneration = 0

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    /// Load (or reload) the tree. Idempotent and safe to call repeatedly.
    func reload() {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            let result = await ProjectService.loadTree(workingDirectory: workingDirectory)
            guard gen == loadGeneration else { return }
            rootNode = result.root
            isGitRepo = result.isGitRepo
            treeTruncated = result.truncated
            isLoading = false
            // Drop any selection that no longer exists in the tree.
            if let url = selectedFileURL, !containsFile(url, in: result.root) {
                clearSelection()
            }
            // Seed the keyboard cursor on the first visible node so the user
            // can start arrow-navigating immediately after the tree loads.
            if focusedNodeURL == nil || findNode(focusedNodeURL!) == nil {
                focusedNodeURL = visibleNodes.first?.url
            }
        }
    }

    /// Open a file in the viewer. No-op for directories.
    func select(node: ProjectFileNode) {
        guard !node.isDirectory else { return }
        if selectedFileURL == node.url { return }
        selectedFileURL = node.url
        selectedFileContent = nil
        selectedFileIsBinary = false
        selectedFileTruncated = false
        selectedFileLanguage = nil
        selectedFileIsLoading = true
        fileLoadGeneration &+= 1
        let gen = fileLoadGeneration
        let url = node.url
        Task { @MainActor in
            let content = await ProjectService.loadFileContent(url: url)
            guard gen == fileLoadGeneration, selectedFileURL == url else { return }
            selectedFileContent = content.text
            selectedFileIsBinary = content.isBinary
            selectedFileTruncated = content.truncated
            selectedFileLanguage = content.language
            selectedFileIsLoading = false
        }
    }

    /// Close the file viewer.
    func clearSelection() {
        selectedFileURL = nil
        selectedFileContent = nil
        selectedFileIsBinary = false
        selectedFileTruncated = false
        selectedFileLanguage = nil
        selectedFileIsLoading = false
        fileLoadGeneration &+= 1
    }

    func isExpanded(_ node: ProjectFileNode) -> Bool {
        expandedURLs.contains(node.url)
    }

    func toggleExpansion(_ node: ProjectFileNode) {
        guard node.isDirectory else { return }
        if expandedURLs.contains(node.url) {
            expandedURLs.remove(node.url)
        } else {
            expandedURLs.insert(node.url)
        }
    }

    private func containsFile(_ url: URL, in node: ProjectFileNode) -> Bool {
        if !node.isDirectory && node.url == url { return true }
        guard let children = node.children else { return false }
        for child in children where containsFile(url, in: child) { return true }
        return false
    }

    // MARK: - Keyboard navigation

    /// Flat list of currently-visible tree rows (root children + recursive
    /// children under expanded folders). Recomputed on each access — the
    /// tree is small enough that walking it on every keystroke is cheap.
    var visibleNodes: [ProjectFileNode] {
        guard let root = rootNode, let children = root.children else { return [] }
        var result: [ProjectFileNode] = []
        func walk(_ nodes: [ProjectFileNode]) {
            for node in nodes {
                result.append(node)
                if node.isDirectory, isExpanded(node), let kids = node.children {
                    walk(kids)
                }
            }
        }
        walk(children)
        return result
    }

    /// Move the tree cursor up (-1) or down (+1) through the visible list.
    /// Clamps at both ends; no wrap-around.
    func moveFocus(by delta: Int) {
        let nodes = visibleNodes
        guard !nodes.isEmpty else { return }
        let currentIndex: Int
        if let url = focusedNodeURL, let idx = nodes.firstIndex(where: { $0.url == url }) {
            currentIndex = idx
        } else {
            currentIndex = -1
        }
        let newIndex = max(0, min(nodes.count - 1, currentIndex + delta))
        focusedNodeURL = nodes[newIndex].url
    }

    /// Right arrow: expand a collapsed folder, or jump into its first child
    /// if already expanded. No-op on files.
    func handleRightArrow() {
        guard let url = focusedNodeURL, let node = findNode(url), node.isDirectory else { return }
        if isExpanded(node) {
            if let first = node.children?.first {
                focusedNodeURL = first.url
            }
        } else {
            expandedURLs.insert(node.url)
        }
    }

    /// Left arrow: collapse an expanded folder, otherwise jump to the parent.
    /// At the top level with no parent, no-op.
    func handleLeftArrow() {
        guard let url = focusedNodeURL, let node = findNode(url) else { return }
        if node.isDirectory && isExpanded(node) {
            expandedURLs.remove(node.url)
            return
        }
        if let parent = parent(of: node) {
            focusedNodeURL = parent.url
        }
    }

    /// Enter: toggle expansion on folders; open + hand keyboard focus to the
    /// file viewer on files.
    func activateFocusedNode() {
        guard let url = focusedNodeURL, let node = findNode(url) else { return }
        if node.isDirectory {
            toggleExpansion(node)
        } else {
            select(node: node)
            requestFocus(.viewer)
        }
    }

    /// Re-assert keyboard focus on the named pane. The generation counter
    /// always advances so observers in the views can act even when the
    /// target hasn't changed.
    func requestFocus(_ target: FocusTarget) {
        focusTarget = target
        focusGeneration &+= 1
    }

    private func findNode(_ url: URL) -> ProjectFileNode? {
        guard let root = rootNode, let children = root.children else { return nil }
        func walk(_ nodes: [ProjectFileNode]) -> ProjectFileNode? {
            for node in nodes {
                if node.url == url { return node }
                if node.isDirectory, let kids = node.children, let found = walk(kids) {
                    return found
                }
            }
            return nil
        }
        return walk(children)
    }

    private func parent(of target: ProjectFileNode) -> ProjectFileNode? {
        guard let root = rootNode, let children = root.children else { return nil }
        func walk(_ nodes: [ProjectFileNode], parent: ProjectFileNode?) -> ProjectFileNode? {
            for node in nodes {
                if node.url == target.url { return parent }
                if node.isDirectory, let kids = node.children,
                   let found = walk(kids, parent: node) {
                    return found
                }
            }
            return nil
        }
        return walk(children, parent: nil)
    }
}
#endif
