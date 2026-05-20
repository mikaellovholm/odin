#if os(macOS)
import SwiftUI

struct ReviewPaneView: View {
    @Bindable var viewModel: ReviewViewModel
    let parentSessionId: String?
    let workingDirectory: String
    /// Deep-link from a finding's location header into the project panel.
    /// `file` is the repo-relative path the reviewer reported; `line` is
    /// 1-based or nil for file-level findings. The host (`ClaudeSessionDetailView`)
    /// is responsible for showing the project panel and forwarding to
    /// `ProjectPanelViewModel.openFile(at:line:)`.
    let onOpenFile: (_ file: String, _ line: Int?) -> Void

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
                FindingsList(
                    run: run,
                    onFix: { triggerFix($0) },
                    onOpenFile: onOpenFile
                )
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

    /// Auto-fixable + still-unfixed blockers — what clicking "Fix blockers"
    /// actually dispatches.
    private var blockerCount: Int {
        run.findings.filter(\.isUnfixedBlocker).count
    }

    /// All unfixed blockers regardless of fixability — used to surface
    /// "and N manual" in the tooltip when some require human judgement.
    private var unfixedBlockerTotal: Int {
        run.findings.filter { $0.severity == .blocker && $0.isUnfixedAny }.count
    }

    private var autoCount: Int {
        run.findings.filter(\.isUnfixedFixable).count
    }

    /// All unfixed findings regardless of fixability — same purpose as
    /// `unfixedBlockerTotal` but for the "all auto-fixable" button.
    private var unfixedTotal: Int {
        run.findings.filter(\.isUnfixedAny).count
    }

    var body: some View {
        HStack(spacing: 8) {
            Button("Fix blockers (\(blockerCount))", action: onFixBlockers)
                .disabled(blockerCount == 0)
                .help(blockerTooltip)
            Button("Fix auto-fixable (\(autoCount))", action: onFixAuto)
                .disabled(autoCount == 0)
                .help(autoTooltip)
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

    private var blockerTooltip: String {
        let manual = unfixedBlockerTotal - blockerCount
        if blockerCount == 0 && manual == 0 {
            return "No unfixed blockers"
        }
        if manual > 0 {
            return "Spawn fix workers for \(blockerCount) auto-fixable blocker\(blockerCount == 1 ? "" : "s"). \(manual) blocker\(manual == 1 ? "" : "s") still need human judgement (shown as 'manual' on their cards)."
        }
        return "Spawn fix workers for all \(blockerCount) unfixed blocker\(blockerCount == 1 ? "" : "s")."
    }

    private var autoTooltip: String {
        let manual = unfixedTotal - autoCount
        if autoCount == 0 && manual == 0 {
            return "No unfixed findings"
        }
        if manual > 0 {
            return "Spawn fix workers for \(autoCount) auto-fixable finding\(autoCount == 1 ? "" : "s"). \(manual) finding\(manual == 1 ? "" : "s") still need human judgement (shown as 'manual' on their cards)."
        }
        return "Spawn fix workers for all \(autoCount) unfixed finding\(autoCount == 1 ? "" : "s")."
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

    /// Concern names from each finding in this card, deduplicated while
    /// preserving the order they were submitted in. Two reviewers from
    /// different concerns flagging the same line both show up (the value of
    /// the dedupe); the same reviewer submitting N findings at the same line
    /// shows up once (preventing `[correctness] [correctness] [correctness]`
    /// noise).
    var uniqueConcerns: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for finding in findings where seen.insert(finding.concern).inserted {
            ordered.append(finding.concern)
        }
        return ordered
    }
}

private struct FindingsList: View {
    let run: ReviewRun
    let onFix: ([ReviewFinding]) -> Void
    let onOpenFile: (_ file: String, _ line: Int?) -> Void

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
                                    onFix: { onFix(location.findings) },
                                    onOpenFile: onOpenFile
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                Divider()
                            }
                        } header: {
                            FileSectionHeader(
                                file: group.file,
                                count: group.locations.reduce(0) { $0 + $1.findings.count },
                                onOpen: { onOpenFile(group.file, nil) }
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
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(file) in the project panel")
        .accessibilityLabel("Open \(file)")
        .accessibilityHint("\(count) finding\(count == 1 ? "" : "s")")
    }
}

// MARK: - Location card

private struct LocationCard: View {
    let group: LocationGroup
    let onFix: () -> Void
    let onOpenFile: (_ file: String, _ line: Int?) -> Void
    /// Per-finding disclosure state. Ephemeral by design — when the user
    /// scrolls past a card or the review run gets replaced, we'd rather start
    /// fresh than carry stale "expanded" flags around.
    @State private var expandedFindings: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(group.findings) { finding in
                FindingDetail(
                    finding: finding,
                    isExpanded: expandedFindings.contains(finding.id),
                    onToggle: { toggle(finding.id) }
                )
            }
        }
    }

    private func toggle(_ id: String) {
        if expandedFindings.contains(id) {
            expandedFindings.remove(id)
        } else {
            expandedFindings.insert(id)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SeverityBadge(severity: group.worstSeverity)
            // One chip per *distinct* concern that flagged this location. The
            // distinct count matters — a card with three findings all from
            // `correctness` shouldn't render three identical chips.
            ForEach(group.uniqueConcerns, id: \.self) { concern in
                Text(concern)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if let line = group.line {
                Button {
                    onOpenFile(group.file, line)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                        Text(":\(line)")
                            .font(.caption.monospaced())
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(group.file):\(line) in the project panel")
                .accessibilityLabel("Open \(group.file) at line \(line)")
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

    /// True only when at least one finding in this card is in a state where
    /// dispatching a fix worker makes sense. Shares its definition with
    /// `ReviewFinding.isDispatchable` so the Fix button is never shown for a
    /// card where clicking it would silently dispatch nothing.
    ///
    /// Counter-example that motivated this: a card with [fixable-A(.applied),
    /// non-fixable-B(.none)]. Without the fixState guard, anyFixable=true and
    /// the Fix button stays on even though `isDispatchable` returns false for
    /// both findings — A is already applied, B is not fixable.
    private var anyFixable: Bool {
        group.findings.contains(where: \.isDispatchable)
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
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                        .padding(.top, 3)
                    Text(finding.title)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(finding.title)
            .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    proseText(finding.detail)
                    if let suggestion = finding.suggestion, !suggestion.isEmpty {
                        suggestionView(suggestion)
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: isExpanded)
    }

    /// Render a body of prose with inline markdown (backticks → inline code).
    /// `.inlineOnlyPreservingWhitespace` keeps newlines from the source string
    /// instead of collapsing the whole thing onto one line — review descriptions
    /// regularly span multiple paragraphs.
    @ViewBuilder
    private func proseText(_ raw: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
        Text(attributed)
            .font(.callout)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Suggestions usually contain a short prose intro followed by a fenced
    /// code block, e.g. "Restore the return:\n```go\nif err != nil { … }\n```".
    /// We split those parts and render the code with syntax highlighting.
    @ViewBuilder
    private func suggestionView(_ raw: String) -> some View {
        let parts = SuggestionParser.parse(raw)
        VStack(alignment: .leading, spacing: 6) {
            if !parts.prose.isEmpty {
                proseText(parts.prose)
            }
            if !parts.code.isEmpty {
                codeBlock(parts.code, language: parts.language)
            }
        }
    }

    @ViewBuilder
    private func codeBlock(_ code: String, language: String?) -> some View {
        let lines = code.components(separatedBy: "\n")
        let isDark = colorScheme == .dark
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(SyntaxHighlighter.shared.highlight(
                    line: line.isEmpty ? " " : line,
                    language: language,
                    isDark: isDark
                ))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(isDark ? 0.45 : 0.85),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }
}

/// Minimal parser for the `prose…\n```lang\ncode\n``` ` shape that review
/// findings emit in their `suggestion` field. No fence → everything is prose.
private struct SuggestionParser {
    struct Parts {
        var prose: String
        var code: String
        var language: String?
    }

    static func parse(_ raw: String) -> Parts {
        let lines = raw.components(separatedBy: "\n")
        guard let openIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) else {
            return Parts(prose: raw, code: "", language: nil)
        }
        let openLine = lines[openIndex].trimmingCharacters(in: .whitespaces)
        let language = String(openLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        let prose = lines[..<openIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let afterFence = lines[(openIndex + 1)...]
        let closeRelative = afterFence.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "```" }
        let codeSlice: ArraySlice<String>
        if let closeRelative {
            codeSlice = afterFence[..<closeRelative]
        } else {
            codeSlice = afterFence
        }
        let code = codeSlice.joined(separator: "\n")
        return Parts(
            prose: prose,
            code: code,
            language: language.isEmpty ? nil : language
        )
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

extension ReviewFinding {
    /// "Fix worker dispatch makes sense for this finding": it's marked
    /// fixable AND is in a state we'd actually act on (untouched / previously
    /// failed / previously skipped). The single source of truth shared by the
    /// view model's bulk dispatch path, the location-card Fix button, and the
    /// bulk-action bar's counts.
    var isDispatchable: Bool {
        guard fixable else { return false }
        return isUnfixed
    }

    /// Unfixed regardless of whether the finding is auto-fixable. Used by the
    /// bulk action bar to show "N auto-fixable + M manual" instead of silently
    /// dropping non-fixable findings from the count.
    var isUnfixedAny: Bool {
        isUnfixed
    }

    var isUnfixedBlocker: Bool {
        severity == .blocker && isDispatchable
    }

    var isUnfixedFixable: Bool {
        isDispatchable
    }

    private var isUnfixed: Bool {
        switch fixState {
        case .none, .failed, .skipped: return true
        case .queued, .running, .applied: return false
        }
    }
}
#endif
