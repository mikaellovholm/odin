#if os(macOS)
import SwiftUI

struct DiffPaneView: View {
    @Bindable var viewModel: DiffViewModel
    @FocusState private var fileListFocused: Bool
    /// Only force focus on the very first file-list materialisation. Without
    /// this latch, every later refresh (e.g. file save → FSEvents → reload)
    /// would yank focus out of whatever the user has selected — including the
    /// diff body or another pane.
    @State private var didInitialFocus = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !viewModel.isGitRepo {
                emptyState(
                    icon: "folder.badge.questionmark",
                    title: "Not a git repository",
                    subtitle: viewModel.workingDirectory
                )
            } else if viewModel.files.isEmpty {
                emptyState(
                    icon: "checkmark.circle",
                    title: "No uncommitted changes",
                    subtitle: nil
                )
            } else {
                VStack(spacing: 0) {
                    fileList
                        .frame(height: fileListHeight)
                    Divider()
                    diffArea
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.activate()
            // Try to focus immediately. If `activate()` has already cached
            // files, this lands now; otherwise the onChange path below picks
            // it up once the first refresh completes.
            focusFileList()
        }
        .onChange(of: viewModel.files.isEmpty) { _, isEmpty in
            // Re-assert focus once the initial file load lands — `.activate()`
            // refreshes async, so the very first `onAppear` focus call races
            // the file list materialising. Latched so later refreshes (FSEvents
            // → reload) don't steal focus from the user.
            guard !didInitialFocus, !isEmpty else { return }
            focusFileList()
            didInitialFocus = true
        }
        .onDisappear { viewModel.deactivate() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Changes")
                .font(.headline)
            if !viewModel.files.isEmpty {
                Text("\(viewModel.files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
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
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var fileList: some View {
        List(selection: selectionBinding) {
            ForEach(viewModel.files) { file in
                ChangedFileRow(file: file)
                    .tag(file.id)
            }
        }
        .listStyle(.plain)
        .focused($fileListFocused)
    }

    private func focusFileList() {
        DispatchQueue.main.async {
            fileListFocused = true
        }
    }

    /// Caps the file list at 6.5 rows so the diff body always gets the lion's
    /// share of the pane. The half row hints there's more to scroll to.
    private var fileListHeight: CGFloat {
        let rowHeight: CGFloat = 36
        let maxRows: CGFloat = 6.5
        let visible = min(CGFloat(viewModel.files.count), maxRows)
        return visible * rowHeight
    }

    @ViewBuilder
    private var diffArea: some View {
        if let file = viewModel.selectedFile {
            UnifiedDiffView(
                file: file,
                hunks: viewModel.selectedDiff ?? [],
                isBinary: viewModel.selectedIsBinary,
                isTruncated: viewModel.selectedTruncated
            )
        } else {
            emptyState(
                icon: "doc.text",
                title: "Select a file",
                subtitle: nil
            )
        }
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

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedFileID },
            set: { newID in
                guard let newID,
                      let file = viewModel.files.first(where: { $0.id == newID })
                else { return }
                viewModel.select(file)
            }
        )
    }
}
#endif
