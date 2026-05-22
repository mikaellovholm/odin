#if os(macOS)
import Foundation

/// Read-only file-tree + file-content loader backing the project side panel.
/// Async wrappers around `git ls-files` (for git repos) and `FileManager` (for
/// plain folders). All process work runs on a background queue so the UI
/// thread never blocks.
enum ProjectService {
    /// Hard cap on total nodes in the tree. Protects the UI from accidentally
    /// loading huge directories (node_modules etc. in non-git folders).
    static let maxNodes = 20_000

    /// Hard cap on bytes read from a file for the viewer. ~1 MB is plenty for
    /// human-edited source files; anything bigger gets truncated with a
    /// footer.
    static let maxFileBytes = 1_024 * 1_024

    struct LoadedTree {
        let root: ProjectFileNode
        let isGitRepo: Bool
        let truncated: Bool
    }

    struct FileContent {
        let text: String?
        let isBinary: Bool
        let truncated: Bool
        let language: String?
    }

    /// Load the full tree for `workingDirectory`. For git repos uses
    /// `git ls-files --others --cached --exclude-standard -z` so the tree
    /// honours `.gitignore`. For non-git folders walks `FileManager`, skipping
    /// dotfiles and `.git`.
    static func loadTree(workingDirectory: String) async -> LoadedTree {
        let rootURL = URL(fileURLWithPath: workingDirectory)
        let rootName = rootURL.lastPathComponent.isEmpty ? workingDirectory : rootURL.lastPathComponent

        let isRepo = await isGitRepo(workingDirectory)
        if isRepo {
            let (paths, truncated) = await gitFilePaths(in: workingDirectory)
            let children = buildTree(rootURL: rootURL, relativePaths: paths)
            let root = ProjectFileNode(
                url: rootURL,
                name: rootName,
                isDirectory: true,
                children: children
            )
            return LoadedTree(root: root, isGitRepo: true, truncated: truncated)
        } else {
            let (children, truncated) = await walkFilesystem(rootURL: rootURL)
            let root = ProjectFileNode(
                url: rootURL,
                name: rootName,
                isDirectory: true,
                children: children
            )
            return LoadedTree(root: root, isGitRepo: false, truncated: truncated)
        }
    }

    /// Load file contents for the viewer. Returns text + binary + truncation
    /// flags. NUL byte in the first 8 KB classifies as binary (same heuristic
    /// as the diff service).
    static func loadFileContent(url: URL) async -> FileContent {
        await withCheckedContinuation { (cont: CheckedContinuation<FileContent, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let language = languageForPath(url.path)
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    cont.resume(returning: FileContent(text: nil, isBinary: false, truncated: false, language: language))
                    return
                }
                defer { try? handle.close() }

                // Read in one bounded shot. Files larger than the cap come
                // back marked truncated.
                let data = handle.readData(ofLength: maxFileBytes + 1)
                let truncated = data.count > maxFileBytes
                let body = truncated ? data.prefix(maxFileBytes) : data

                // Binary check on the first 8 KB.
                let head = body.prefix(8 * 1024)
                if head.contains(0) {
                    cont.resume(returning: FileContent(text: nil, isBinary: true, truncated: truncated, language: language))
                    return
                }

                let text = String(data: Data(body), encoding: .utf8)
                    ?? String(data: Data(body), encoding: .isoLatin1)
                cont.resume(returning: FileContent(
                    text: text,
                    isBinary: text == nil,
                    truncated: truncated,
                    language: language
                ))
            }
        }
    }

    static func isGitRepo(_ cwd: String) async -> Bool {
        let r = await GitCommand.run(["rev-parse", "--git-dir"], cwd: cwd)
        return r.exitCode == 0
    }

    // MARK: - Git path listing

    /// Returns all non-ignored relative paths in the repo, plus a `truncated`
    /// flag if we hit the node cap.
    private static func gitFilePaths(in cwd: String) async -> (paths: [String], truncated: Bool) {
        // --others includes untracked-but-not-ignored; --cached includes
        // tracked files; --exclude-standard honours .gitignore /
        // .git/info/exclude / core.excludesFile. -z gives NUL-separated paths
        // (safe for any filename).
        let r = await GitCommand.run(
            ["ls-files", "--others", "--cached", "--exclude-standard", "-z"],
            cwd: cwd
        )
        guard r.exitCode == 0 else { return ([], false) }
        // De-dupe (a path can appear in both --cached and --others in rare
        // states) while preserving order.
        var seen = Set<String>()
        var paths: [String] = []
        var truncated = false
        for part in r.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let path = String(part)
            if seen.insert(path).inserted {
                paths.append(path)
                if paths.count >= maxNodes {
                    truncated = true
                    break
                }
            }
        }
        return (paths, truncated)
    }

    /// Build a sorted tree from a flat list of POSIX-style relative paths.
    /// Folders are inserted on demand from each file's path components.
    private static func buildTree(rootURL: URL, relativePaths: [String]) -> [ProjectFileNode] {
        // Use a recursive scratch type so children can be mutated in-place
        // while building, then convert to immutable `ProjectFileNode` once
        // we're done.
        final class Scratch {
            let url: URL
            let name: String
            let isDirectory: Bool
            var childrenByName: [String: Scratch] = [:]
            init(url: URL, name: String, isDirectory: Bool) {
                self.url = url
                self.name = name
                self.isDirectory = isDirectory
            }
        }

        let scratchRoot = Scratch(url: rootURL, name: rootURL.lastPathComponent, isDirectory: true)
        for rel in relativePaths {
            // Skip empty / "." / ".." just in case.
            let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.isEmpty { continue }
            var current = scratchRoot
            var currentURL = rootURL
            for (index, part) in parts.enumerated() {
                currentURL = currentURL.appendingPathComponent(part)
                let isLeaf = index == parts.count - 1
                if let existing = current.childrenByName[part] {
                    current = existing
                } else {
                    let node = Scratch(url: currentURL, name: part, isDirectory: !isLeaf)
                    current.childrenByName[part] = node
                    current = node
                }
            }
        }

        func materialize(_ s: Scratch) -> ProjectFileNode {
            if s.isDirectory {
                let sortedChildren = s.childrenByName.values.sorted { a, b in
                    // Directories first, then files, alphabetical within each.
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                return ProjectFileNode(
                    url: s.url,
                    name: s.name,
                    isDirectory: true,
                    children: sortedChildren.map(materialize)
                )
            } else {
                return ProjectFileNode(url: s.url, name: s.name, isDirectory: false, children: nil)
            }
        }

        return materialize(scratchRoot).children ?? []
    }

    // MARK: - Filesystem walk (non-git folders)

    private static func walkFilesystem(rootURL: URL) async -> (children: [ProjectFileNode], truncated: Bool) {
        await withCheckedContinuation { (cont: CheckedContinuation<([ProjectFileNode], Bool), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var totalNodes = 0
                var truncated = false

                func walk(_ url: URL) -> [ProjectFileNode] {
                    guard !truncated else { return [] }
                    let contents: [URL]
                    do {
                        contents = try FileManager.default.contentsOfDirectory(
                            at: url,
                            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                            options: [.skipsHiddenFiles]
                        )
                    } catch {
                        return []
                    }

                    var nodes: [ProjectFileNode] = []
                    for child in contents {
                        if totalNodes >= maxNodes {
                            truncated = true
                            break
                        }
                        let name = child.lastPathComponent
                        if name == ".git" { continue }
                        let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if values?.isSymbolicLink == true { continue }
                        let isDir = values?.isDirectory == true
                        totalNodes += 1
                        if isDir {
                            let grandchildren = walk(child)
                            nodes.append(ProjectFileNode(
                                url: child,
                                name: name,
                                isDirectory: true,
                                children: grandchildren
                            ))
                        } else {
                            nodes.append(ProjectFileNode(
                                url: child,
                                name: name,
                                isDirectory: false,
                                children: nil
                            ))
                        }
                    }

                    nodes.sort { a, b in
                        if a.isDirectory != b.isDirectory { return a.isDirectory }
                        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                    return nodes
                }

                let result = walk(rootURL)
                cont.resume(returning: (result, truncated))
            }
        }
    }

    // MARK: - Language detection

    /// Thin wrapper around `SyntaxHighlighter.language(forPath:)`. Defined here
    /// so the service can resolve a language label without hopping to
    /// `@MainActor`.
    private static func languageForPath(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "go": return "go"
        case "kt", "kts": return "kotlin"
        case "py": return "python"
        case "ts", "tsx": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "xml"
        case "xml", "plist": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "sh", "bash", "zsh": return "bash"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "java": return "java"
        case "m", "mm": return "objectivec"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp": return "cpp"
        case "toml": return "ini"
        case "sql": return "sql"
        default:
            let name = (path as NSString).lastPathComponent.lowercased()
            switch name {
            case "dockerfile": return "dockerfile"
            case "makefile": return "makefile"
            case ".gitignore", ".dockerignore": return "ini"
            default: return nil
            }
        }
    }

}
#endif
