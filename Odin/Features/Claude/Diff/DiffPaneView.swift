#if os(macOS)
import SwiftUI

struct DiffPaneView: View {
    @Bindable var viewModel: DiffViewModel

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
                VSplitView {
                    fileList
                        .frame(minHeight: 80, idealHeight: 180)
                    diffArea
                        .frame(minHeight: 120, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.activate() }
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
