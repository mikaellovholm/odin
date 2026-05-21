#if os(macOS)
import SwiftUI
import MarkdownUI

/// Read-only viewer for the file currently selected in the project panel.
/// Renders line numbers + Highlightr-syntax-highlighted text. Binary files
/// show a placeholder.
struct FileViewerView: View {
    let workingDirectory: String
    @Bindable var viewModel: ProjectPanelViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var contentFocused: Bool
    /// Keyboard-cursor line (0-indexed). Resets to 0 whenever a new file is
    /// opened. Local to the view because it doesn't need to survive
    /// detail-view rebuilds — opening a file always starts at line 1.
    @State private var focusedLine: Int = 0
    /// Cached split of the current file's content. Recomputed only when the
    /// underlying text changes — without this, every arrow keypress would
    /// re-split the whole file (`focusedLine` bumps re-trigger body).
    @State private var cachedLines: [String] = []
    /// Identity for the currently-cached lines. We key on `(url, byte count)`
    /// because the view model may load a fresh file at the same URL after a
    /// refresh; pointer identity isn't available for Swift strings.
    @State private var cachedLinesKey: String?
    /// True when the user has toggled the markdown preview on. Persists across
    /// file switches inside a single viewer mount — opening another `.md` file
    /// stays in preview mode, opening a non-md file just hides the toggle.
    @State private var showPreview: Bool = false

    private var isDark: Bool { colorScheme == .dark }
    private var isMarkdown: Bool { viewModel.selectedFileLanguage == "markdown" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focused($contentFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .escape]) { press in
            switch press.key {
            case .escape:
                viewModel.clearSelection()
                viewModel.requestFocus(.tree)
                return .handled
            case .upArrow:
                guard !cachedLines.isEmpty else { return .ignored }
                focusedLine = max(0, focusedLine - 1)
                return .handled
            case .downArrow:
                guard !cachedLines.isEmpty else { return .ignored }
                focusedLine = min(cachedLines.count - 1, focusedLine + 1)
                return .handled
            default:
                return .ignored
            }
        }
        // VM bumps the generation counter when the user presses Enter on a
        // file in the tree. We grab keyboard focus and reset to line 1.
        .onChange(of: viewModel.focusGeneration) { _, _ in
            if viewModel.focusTarget == .viewer {
                focusedLine = 0
                DispatchQueue.main.async { contentFocused = true }
            }
        }
        // Opening a new file (by any path — click, Enter, etc.) resets the
        // cursor too. Without this, the cursor could land beyond the new
        // file's last line when switching from a longer file. A queued
        // `pendingFocusLine` (set by an external deep-link like the review
        // pane) takes precedence and is applied once content arrives below.
        .onChange(of: viewModel.selectedFileURL) { _, _ in
            focusedLine = 0
        }
        // If a deep-link arrived for the file already open (no URL change),
        // apply the pending line as soon as it's set. For brand-new files,
        // `cachedLines` is empty here and the content-arrival handler in
        // `content` picks it up instead.
        .onChange(of: viewModel.pendingFocusLine) { _, newValue in
            applyPendingFocusLineIfReady(newValue)
        }
    }

    /// Clamp the pending line to the loaded file's line count, grab keyboard
    /// focus, and clear the pending slot. No-op when the cache isn't ready for
    /// the currently-selected file — the content-arrival handler retries.
    /// Critically, we check that the cache key matches the current URL before
    /// applying: when a deep-link switches files, `pendingFocusLine` is set
    /// while `cachedLines` still holds the *previous* file's lines, and naively
    /// applying would (a) clamp to the wrong line count, (b) prematurely clear
    /// the pending slot before the new file's content arrives.
    private func applyPendingFocusLineIfReady(_ line: Int?) {
        guard let line else { return }
        guard !cachedLines.isEmpty else { return }
        let currentURL = viewModel.selectedFileURL?.path ?? ""
        guard let key = cachedLinesKey, key.hasPrefix("\(currentURL)|") else { return }
        focusedLine = min(max(0, line), cachedLines.count - 1)
        DispatchQueue.main.async { contentFocused = true }
        viewModel.pendingFocusLine = nil
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(relativeDisplayPath)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if isMarkdown && !viewModel.selectedFileIsBinary {
                ShortcutKey("⇧⌘M")
                Button {
                    showPreview.toggle()
                } label: {
                    Image(systemName: showPreview ? "chevron.left.forwardslash.chevron.right" : "eye")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(showPreview ? "Show source (⇧⌘M)" : "Show preview (⇧⌘M)")
                .keyboardShortcut("m", modifiers: [.shift, .command])
            }
            ShortcutKey("esc")
            Button {
                viewModel.clearSelection()
                viewModel.requestFocus(.tree)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close file (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedFileIsLoading {
            placeholder(icon: nil, title: nil, progress: true)
        } else if viewModel.selectedFileIsBinary {
            placeholder(icon: "doc", title: "Binary file — preview not available", progress: false)
        } else if let text = viewModel.selectedFileContent {
            if isMarkdown && showPreview {
                markdownPreview(text: text)
            } else {
                body(text: text)
                // Recompute the line split only when the file content actually
                // changes — without this, every arrow keypress would re-split
                // a potentially-huge file as a side-effect of body re-eval.
                .onAppear {
                    refreshCachedLines(text: text)
                    applyPendingFocusLineIfReady(viewModel.pendingFocusLine)
                }
                .onChange(of: viewModel.selectedFileURL) { _, _ in
                    refreshCachedLines(text: text)
                    applyPendingFocusLineIfReady(viewModel.pendingFocusLine)
                }
                .onChange(of: viewModel.selectedFileContent) { _, newText in
                    refreshCachedLines(text: newText ?? "")
                    applyPendingFocusLineIfReady(viewModel.pendingFocusLine)
                }
            }
        } else {
            placeholder(icon: "exclamationmark.triangle", title: "Couldn't read file", progress: false)
        }
    }

    private func markdownPreview(text: String) -> some View {
        ScrollView(.vertical) {
            if text.isEmpty {
                Text("Empty file")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                Markdown(text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if viewModel.selectedFileTruncated {
                truncationFooter
            }
        }
    }

    private func body(text: String) -> some View {
        // `cachedLines` is populated by `refreshCachedLines(text:)` whenever
        // the file content changes. `LazyVStack` ensures only visible rows
        // materialize so even a 25K-line file stays smooth.
        // If the cache hasn't caught up yet (first body eval after a file
        // switch, before `.onChange` fires), split inline so we don't flash
        // stale rows from the previous file.
        let cacheIsCurrent = cachedLinesKey == "\(viewModel.selectedFileURL?.path ?? "")|\(text.utf8.count)"
        let lines: [String] = cacheIsCurrent
            ? cachedLines
            : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Size the gutter to the actual line count so a 20-line file doesn't
        // get a 4-digit-wide gutter. ~7pt per monospaced digit at 10pt, plus
        // a small floor so even single-digit files have a touch of breathing
        // room.
        let gutterWidth = max(20, CGFloat(String(lines.count).count) * 7 + 6)
        // Vertical scroll only — matches the diff pane. With a horizontal
        // scroll view the row's `.frame(maxWidth: .infinity)` collapses to
        // the text's intrinsic size and lines wrap narrowly. Vertical-only
        // lets the row fill the column and reflow on resize.
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        FileLineRow(
                            lineNumber: index + 1,
                            line: line,
                            language: viewModel.selectedFileLanguage,
                            isDark: isDark,
                            gutterWidth: gutterWidth,
                            isFocused: index == focusedLine && contentFocused
                        )
                        .id(index)
                    }
                    if viewModel.selectedFileTruncated {
                        truncationFooter
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: focusedLine) { _, new in
                // Keep the cursor on-screen. `.center` matches what most
                // editors do — the cursor isn't pinned to an edge, so a
                // single keypress doesn't trigger a big jump.
                proxy.scrollTo(new, anchor: .center)
            }
            // When this source view re-mounts after a markdown-preview toggle,
            // the ScrollView is fresh and starts at the top — even though
            // `focusedLine` survives on the parent. Restore the cursor's spot.
            // Skip line 0 so the first-mount of a new file isn't oddly
            // centered (the natural top-aligned scroll handles that).
            .onAppear {
                if focusedLine > 0 {
                    proxy.scrollTo(focusedLine, anchor: .center)
                }
            }
        }
    }

    /// Recompute `cachedLines` for the given text, but only if the file
    /// identity changed since the last cache. Keying on `(url, byteCount)`
    /// catches both file-switches and same-URL refreshes.
    private func refreshCachedLines(text: String) {
        let url = viewModel.selectedFileURL?.path ?? ""
        let key = "\(url)|\(text.utf8.count)"
        guard key != cachedLinesKey else { return }
        cachedLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        cachedLinesKey = key
    }

    private var truncationFooter: some View {
        Text("File truncated at \(ProjectService.maxFileBytes / 1024) KB")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
    }

    private func placeholder(icon: String?, title: String?, progress: Bool) -> some View {
        VStack(spacing: 8) {
            if progress {
                ProgressView()
            } else if let icon {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            if let title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Path relative to the working directory, falling back to the bare last
    /// component if the file isn't underneath it for some reason (symlink edge
    /// cases). Cosmetic only — used for the header label.
    private var relativeDisplayPath: String {
        guard let url = viewModel.selectedFileURL else { return "" }
        let base = workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/"
        if url.path.hasPrefix(base) {
            return String(url.path.dropFirst(base.count))
        }
        return url.lastPathComponent
    }
}

private struct FileLineRow: View {
    let lineNumber: Int
    let line: String
    let language: String?
    let isDark: Bool
    let gutterWidth: CGFloat
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(lineNumber))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 8)
            Text(SyntaxHighlighter.shared.highlight(line: line, language: language, isDark: isDark))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .background(isFocused ? Color.accentColor.opacity(0.18) : .clear)
    }
}
#endif
