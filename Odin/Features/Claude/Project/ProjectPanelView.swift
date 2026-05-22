#if os(macOS)
import SwiftUI

/// File-tree side panel rooted at a Claude session's working directory.
/// Toggled via ⇧⌘P. Selecting a file opens it in the adjacent `FileViewerView`.
struct ProjectPanelView: View {
    @Bindable var viewModel: ProjectPanelViewModel
    @FocusState private var panelFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.isLoading && viewModel.rootNode == nil {
                loadingPlaceholder
            } else if let root = viewModel.rootNode, let children = root.children, !children.isEmpty {
                tree(children: children)
            } else if viewModel.rootNode != nil {
                emptyState(
                    icon: viewModel.isGitRepo ? "tray" : "folder",
                    title: viewModel.isGitRepo ? "No tracked files" : "Empty folder",
                    subtitle: viewModel.workingDirectory
                )
            } else {
                emptyState(
                    icon: "folder.badge.questionmark",
                    title: "Couldn't load folder",
                    subtitle: viewModel.errorMessage ?? viewModel.workingDirectory
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Keyboard-focusable container so `.onKeyPress` receives events.
        // Focus effect is hidden — we render our own focused-row tint instead
        // of the system focus ring around the whole panel.
        .focusable()
        .focused($panelFocused)
        .focusEffectDisabled()
        // One `.onKeyPress(keys:)` instead of five chained calls — keeps the
        // modifier chain short enough for SwiftUI's type checker.
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
            switch press.key {
            case .upArrow: viewModel.moveFocus(by: -1)
            case .downArrow: viewModel.moveFocus(by: 1)
            case .leftArrow: viewModel.handleLeftArrow()
            case .rightArrow: viewModel.handleRightArrow()
            case .return: viewModel.activateFocusedNode()
            default: return .ignored
            }
            return .handled
        }
        .onAppear {
            if viewModel.rootNode == nil { viewModel.reload() }
            // Defer to next runloop so the view is in the responder chain
            // before we try to grab focus.
            DispatchQueue.main.async { panelFocused = true }
        }
        // Whenever the VM asks to focus the tree (e.g. ESC-equivalent flows,
        // or initial activation), re-assert keyboard focus here. The
        // generation counter ensures repeated requests still fire even when
        // the value didn't change.
        .onChange(of: viewModel.focusGeneration) { _, _ in
            if viewModel.focusTarget == .tree {
                DispatchQueue.main.async { panelFocused = true }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Project")
                .font(.headline)
            if !viewModel.isGitRepo {
                Text("no git")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .accessibilityLabel("Refresh project tree")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tree(children: [ProjectFileNode]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(children) { node in
                    ProjectTreeRowView(node: node, indent: 0, viewModel: viewModel)
                }
                if viewModel.treeTruncated {
                    truncationFooter
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var loadingPlaceholder: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var truncationFooter: some View {
        Text("Tree truncated at \(ProjectService.maxNodes) entries")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
    }

    private func emptyState(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Recursive row: a file/folder label plus, when the folder is expanded, its
/// children indented one level deeper. SwiftUI's `List(_:children:)` was
/// avoided because clicking a folder row would select it (per SwiftUI's
/// default list behaviour) instead of toggling expansion — we want a folder
/// click to expand and a file click to open. Hand-rolled recursion gives us
/// that control.
private struct ProjectTreeRowView: View {
    let node: ProjectFileNode
    let indent: Int
    @Bindable var viewModel: ProjectPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectRowLabel(
                node: node,
                indent: indent,
                isExpanded: viewModel.isExpanded(node),
                isSelected: viewModel.selectedFileURL == node.url,
                isFocused: viewModel.focusedNodeURL == node.url
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Click moves the keyboard cursor too, so arrow keys continue
                // from where the user last clicked. Re-asserting tree focus
                // means clicking inside the panel also pulls keyboard focus
                // back if it was on the file viewer.
                viewModel.focusedNodeURL = node.url
                viewModel.requestFocus(.tree)
                if node.isDirectory {
                    viewModel.toggleExpansion(node)
                } else {
                    viewModel.select(node: node)
                }
            }

            if node.isDirectory, viewModel.isExpanded(node), let children = node.children {
                ForEach(children) { child in
                    ProjectTreeRowView(node: child, indent: indent + 1, viewModel: viewModel)
                }
            }
        }
    }
}

private struct ProjectRowLabel: View {
    let node: ProjectFileNode
    let indent: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            // Indent guide — 14pt per level matches Finder's column width.
            Color.clear.frame(width: CGFloat(indent) * 14, height: 1)

            // Disclosure chevron for folders, empty spacer for files so the
            // name column aligns vertically.
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 14)

            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // Focus (keyboard cursor) and selection (file open in viewer) can
        // coexist. Focused-only gets a subtle tint; selected gets a stronger
        // accent; both together get the strongest tint so the user can see
        // the cursor sitting on the open file.
        .background(rowBackground)
    }

    private var rowBackground: Color {
        switch (isSelected, isFocused) {
        case (true, true): return Color.accentColor.opacity(0.28)
        case (true, false): return Color.accentColor.opacity(0.18)
        case (false, true): return Color.accentColor.opacity(0.10)
        case (false, false): return .clear
        }
    }
}
#endif
