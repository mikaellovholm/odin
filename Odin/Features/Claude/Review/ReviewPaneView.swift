#if os(macOS)
import SwiftUI

struct ReviewPaneView: View {
    @Bindable var viewModel: ReviewViewModel
    let parentSessionId: String?
    let workingDirectory: String

    var body: some View {
        VStack(spacing: 0) {
            if let run = viewModel.currentRun(parentSessionId: parentSessionId) {
                ReviewPaneHeader(run: run, viewModel: viewModel, parentSessionId: parentSessionId)
                Divider()
                BulkActionBar(
                    run: run,
                    onFixBlockers: { fixBulk(run: run, predicate: \.isUnfixedBlocker) },
                    onFixAuto: { fixBulk(run: run, predicate: \.isUnfixedFixable) }
                )
                Divider()
                FindingsList(run: run, onFix: { triggerFix($0) })
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No review yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Ask Odin to review this branch.\nFindings will appear here live.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerFix(_ findings: [ReviewFinding]) {
        viewModel.triggerFix(
            findings,
            cwd: workingDirectory,
            parentSessionId: parentSessionId
        )
    }

    private func fixBulk(run: ReviewRun, predicate: (ReviewFinding) -> Bool) {
        viewModel.triggerBulkFix(
            in: run,
            predicate: predicate,
            cwd: workingDirectory,
            parentSessionId: parentSessionId
        )
    }
}

// MARK: - Header

private struct ReviewPaneHeader: View {
    let run: ReviewRun
    @Bindable var viewModel: ReviewViewModel
    let parentSessionId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Review")
                    .font(.headline)
                Text(run.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.dismiss(parentSessionId: parentSessionId)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Dismiss this review run")
            }
            if let stat = run.diffStat, !stat.isEmpty {
                Text(stat)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(run.concerns) { concern in
                        ConcernChip(concern: concern)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ConcernChip: View {
    let concern: ReviewConcern

    var body: some View {
        HStack(spacing: 4) {
            statusIcon
            Text(concern.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help(tooltip)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch concern.status {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var tooltip: String {
        switch concern.status {
        case .pending: return "Waiting to start"
        case .running: return "Reviewer running…"
        case .completed: return concern.summary ?? "Completed"
        case .failed(_, let msg): return msg
        }
    }
}

// MARK: - Action bar

private struct BulkActionBar: View {
    let run: ReviewRun
    let onFixBlockers: () -> Void
    let onFixAuto: () -> Void

    private var blockerCount: Int {
        run.findings.filter(\.isUnfixedBlocker).count
    }
    private var autoCount: Int {
        run.findings.filter(\.isUnfixedFixable).count
    }

    var body: some View {
        HStack(spacing: 8) {
            Button("Fix all blockers (\(blockerCount))", action: onFixBlockers)
                .disabled(blockerCount == 0)
            Button("Fix all auto-fixable (\(autoCount))", action: onFixAuto)
                .disabled(autoCount == 0)
            Spacer()
            Text("\(run.findings.count) findings")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Findings list (grouped by file → location card)

/// Findings sharing the same `(file, line)` collapse into one card. Line-less
/// (file-level) findings group into a single per-file card with `line == nil`.
private struct LocationGroup: Identifiable {
    let file: String
    let line: Int?
    let findings: [ReviewFinding]

    var id: String { "\(file)#\(line.map(String.init) ?? "_")" }

    /// The worst (lowest-rawValue, since `ReviewSeverity: Comparable` goes
    /// blocker < major < minor < nit). Drives the card's badge color and the
    /// sort order within a file.
    var worstSeverity: ReviewSeverity {
        findings.map(\.severity).min() ?? .nit
    }

    /// Concern names from each finding in this card, preserving the order they
    /// were submitted in. Duplicate concern names are kept — if correctness
    /// and security both flagged the same line, the user wants to see both.
    var concerns: [String] {
        findings.map(\.concern)
    }
}

private struct FindingsList: View {
    let run: ReviewRun
    let onFix: ([ReviewFinding]) -> Void

    private var groupedFiles: [(file: String, locations: [LocationGroup])] {
        let byFile = Dictionary(grouping: run.findings, by: \.file)
        let groups: [(String, [LocationGroup])] = byFile.map { file, fileFindings in
            let byLine = Dictionary(grouping: fileFindings, by: \.line)
            let locations = byLine
                .map { line, locFindings in
                    LocationGroup(
                        file: file,
                        line: line,
                        findings: locFindings.sorted { $0.severity < $1.severity }
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.worstSeverity != rhs.worstSeverity {
                        return lhs.worstSeverity < rhs.worstSeverity
                    }
                    // Numeric line ascending, with line-less (nil) findings last
                    switch (lhs.line, rhs.line) {
                    case let (.some(l), .some(r)): return l < r
                    case (.some, .none): return true
                    case (.none, .some): return false
                    case (.none, .none): return false
                    }
                }
            return (file, locations)
        }
        return groups.sorted { lhs, rhs in
            let lhsTop = lhs.1.first?.worstSeverity ?? .nit
            let rhsTop = rhs.1.first?.worstSeverity ?? .nit
            if lhsTop != rhsTop { return lhsTop < rhsTop }
            return lhs.0 < rhs.0
        }
    }

    var body: some View {
        if run.findings.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("No findings yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Reviewers are still running.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedFiles, id: \.file) { group in
                        Section {
                            ForEach(group.locations) { location in
                                LocationCard(
                                    group: location,
                                    onFix: { onFix(location.findings) }
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                Divider()
                            }
                        } header: {
                            FileSectionHeader(
                                file: group.file,
                                count: group.locations.reduce(0) { $0 + $1.findings.count }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct FileSectionHeader: View {
    let file: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(file)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }
}

// MARK: - Location card

private struct LocationCard: View {
    let group: LocationGroup
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(group.findings) { finding in
                FindingDetail(finding: finding)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SeverityBadge(severity: group.worstSeverity)
            // Concern chips — one per reviewer that flagged this location.
            // Stacked horizontally; wraps cleanly because each is small.
            ForEach(Array(group.findings.enumerated()), id: \.offset) { _, finding in
                Text(finding.concern)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if let line = group.line {
                Text(":\(line)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            fixControl
        }
    }

    /// Aggregate of all findings' fix states so one Fix button can act on the
    /// whole card. Order matters here: anything in flight (running/queued)
    /// dominates so we don't offer a "Fix" click while a worker for this file
    /// is already mid-edit.
    private var aggregateFixState: AggregateFixState {
        var anyRunning = false
        var anyQueued = false
        var anyApplied = false
        var anyUnfixed = false
        var lastFailedMsg: String?
        var lastSkippedReason: String?
        for f in group.findings {
            switch f.fixState {
            case .running:
                anyRunning = true
            case .queued:
                anyQueued = true
            case .applied:
                anyApplied = true
            case .failed(let msg):
                lastFailedMsg = msg
                anyUnfixed = true
            case .skipped(let reason):
                lastSkippedReason = reason
                anyUnfixed = true
            case .none:
                anyUnfixed = true
            }
        }
        if anyRunning { return .running }
        if anyQueued { return .queued }
        if anyUnfixed {
            return .actionable(
                lastFailure: lastFailedMsg,
                lastSkip: lastSkippedReason
            )
        }
        return anyApplied ? .applied : .actionable(lastFailure: nil, lastSkip: nil)
    }

    private var anyFixable: Bool {
        group.findings.contains(where: { $0.fixable })
    }

    @ViewBuilder
    private var fixControl: some View {
        switch aggregateFixState {
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
                Text("fixing…").font(.caption2).foregroundStyle(.secondary)
            }
        case .queued:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
                Text("queued").font(.caption2).foregroundStyle(.secondary)
            }
        case .applied:
            Label("applied", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .actionable(let lastFailure, let lastSkip):
            if anyFixable {
                Button("Fix", action: onFix)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(fixTooltip(lastFailure: lastFailure, lastSkip: lastSkip))
            } else {
                Text("manual")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Not auto-fixable — needs human judgement")
            }
        }
    }

    private func fixTooltip(lastFailure: String?, lastSkip: String?) -> String {
        if let lastFailure { return "Last fix failed: \(lastFailure). Click to retry." }
        if let lastSkip { return "Skipped previously: \(lastSkip). Click to retry." }
        if group.findings.count > 1 {
            return "Spawn a fix worker for all \(group.findings.count) findings at this location"
        }
        return "Spawn a fix worker"
    }
}

private enum AggregateFixState {
    case running
    case queued
    case applied
    case actionable(lastFailure: String?, lastSkip: String?)
}

private struct FindingDetail: View {
    let finding: ReviewFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(finding.title)
                .font(.callout)
                .lineLimit(2)
            Text(finding.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            if let suggestion = finding.suggestion {
                Text(suggestion)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(4)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

private struct SeverityBadge: View {
    let severity: ReviewSeverity

    var body: some View {
        Text(severity.rawValue)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var color: Color {
        switch severity {
        case .blocker: return .red
        case .major:   return .orange
        case .minor:   return Color(nsColor: .systemYellow)
        case .nit:     return .gray
        }
    }
}

// MARK: - Finding predicates

private extension ReviewFinding {
    var isUnfixedBlocker: Bool {
        guard severity == .blocker, fixable else { return false }
        return isUnfixed
    }

    var isUnfixedFixable: Bool {
        guard fixable else { return false }
        return isUnfixed
    }

    private var isUnfixed: Bool {
        switch fixState {
        case .none, .failed, .skipped: return true
        case .queued, .running, .applied: return false
        }
    }
}
#endif
