import SwiftUI

private enum DayDigestTaskType {
    static var sectionTitle: AppFont { AppFont.scaled(.headline) }
    static var taskTitle: AppFont { AppFont.scaled(.body).weight(.semibold) }
    static var summary: AppFont { AppFont.scaled(.callout) }
}

/// Human-first rendering of the lossless Markdown day journal. Summary and
/// focus stay visible; the forensic activity/evidence trail is available on
/// demand without making every captured moment compete for attention.
struct DayDigestView: View {
    enum Mode: Equatable {
        case standalone
        case timeline
        /// Timeline's content on a wide page: sessions become a card grid and
        /// prose keeps a reading width.
        case today

        var showsMeetings: Bool { self == .standalone }
        var arrangesSessionsInGrid: Bool { self == .today }
        var showsTimeAllocation: Bool { self == .standalone }
        var showsFullActivityLog: Bool { self == .standalone }
        var showsOtherActivity: Bool { self == .standalone }
    }

    let presentation: DayDigestPresentation
    let mode: Mode

    @State private var fullActivityExpanded = false
    @State private var otherActivityExpanded = false
    @State private var timeAllocationExpanded = false
    @State private var sessionGridWidth: CGFloat = 0

    init(_ markdown: String, mode: Mode = .standalone) {
        presentation = DayDigestPresentation(markdown: markdown)
        self.mode = mode
    }

    var body: some View {
        fullContent
    }

    private var fullContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !presentation.blockers.isEmpty {
                blockersCallout
            }

            if !presentation.atAGlanceMarkdown.isEmpty {
                digestSection("Highlights", icon: "sparkles") {
                    SelectableDigestText(presentation.atAGlanceMarkdown)
                        .frame(maxWidth: proseMaxWidth, alignment: .leading)
                }
            }

            if !presentation.decisions.isEmpty {
                digestSection("Decisions", icon: "checkmark.seal") {
                    SelectableDigestText(Self.bulletList(presentation.decisions))
                        .frame(maxWidth: proseMaxWidth, alignment: .leading)
                }
            }

            if !presentation.focusBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "briefcase")
                            .accessibilityHidden(true)
                        Text(mode == .today ? "Tasks" : "Work Summary")
                            .font(DayDigestTaskType.sectionTitle)
                            .accessibilityIdentifier("dayDigest.tasks")
                    }
                    .foregroundStyle(.primary)
                    // Every task stays visible as one scannable line; only
                    // the description of what was done opens on demand.
                    if mode.arrangesSessionsInGrid {
                        sessionGrid
                    } else {
                        taskList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !presentation.followUps.isEmpty {
                digestSection("Follow-ups", icon: "arrow.turn.down.right") {
                    taskRows(presentation.followUps)
                }
            }

            if mode.showsOtherActivity, !presentation.otherActivityBlocks.isEmpty {
                DisclosureGroup(isExpanded: $otherActivityExpanded) {
                    sessionList(presentation.otherActivityBlocks)
                        .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Label("Other activity", systemImage: "ellipsis.circle")
                            .font(.scaled(.subheadline).weight(.medium))
                        Spacer()
                        Text("\(presentation.otherActivityBlocks.count) item\(presentation.otherActivityBlocks.count == 1 ? "" : "s")")
                            .font(.scaled(.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("dayDigest.otherActivity")
                .accessibilityHint("Shorter activities that used a smaller share of the recorded day")
            }

            if mode.showsMeetings, let meetings = presentation.meetingsMarkdown {
                digestSection("Meetings", icon: "person.2") {
                    SelectableDigestText(meetings)
                }
            }

            if mode.showsMeetings, let sessions = presentation.agentSessionsMarkdown {
                digestSection("Agent sessions", icon: "terminal") {
                    SelectableDigestText(sessions)
                }
            }

            if mode.showsTimeAllocation, !presentation.timeAllocations.isEmpty {
                timeAllocationDisclosure
            }

            if mode.showsFullActivityLog, presentation.activityCount > 0 {
                DisclosureGroup(isExpanded: $fullActivityExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(presentation.activityGroups) { group in
                            DayDigestActivityHourView(group: group)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Label("Full activity log", systemImage: "clock.arrow.circlepath")
                            .font(.scaled(.subheadline).weight(.semibold))
                        Spacer()
                        Text("\(presentation.activityCount) events")
                            .font(.scaled(.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("dayDigest.fullActivityLog")
                .accessibilityHint("Contains the complete activity log grouped by hour")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var proseMaxWidth: CGFloat {
        mode == .today ? WorkspaceMetric.readingMaxWidth : .infinity
    }

    private var sessionColumnCount: Int {
        switch sessionGridWidth {
        case 900...: 3
        case 560...: 2
        default: 1
        }
    }

    /// Blockers lead the digest: they are what stops the day's open work.
    private var blockersCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(presentation.blockers.count == 1 ? "Blocker" : "Blockers",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.scaled(.subheadline).weight(.semibold))
                .foregroundStyle(LBTokens.Palette.attentionText)
            SelectableDigestText(presentation.blockers.count == 1
                ? presentation.blockers[0]
                : Self.bulletList(presentation.blockers))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(LBTokens.Palette.attention)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dayDigest.blockers")
    }

    /// Open work first, then finished work, each task on its own line.
    private var taskList: some View {
        let groups = presentation.taskGroups
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    if groups.count > 1 {
                        Text("\(group.kind.title) · \(group.blocks.count)")
                            .font(.scaled(.subheadline).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, 2)
                    }
                    taskRows(group.blocks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskRows(_ blocks: [DayDigestPresentation.FocusBlock]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                DayDigestTaskRow(block: block,
                                 collapsesDetails: presentation.collapsesDetails(of: block))
                    .padding(.vertical, 7)
                if block.id != blocks.last?.id {
                    Divider().padding(.leading, DayDigestTaskRow.textInset)
                }
            }
        }
    }

    private static func bulletList(_ items: [String]) -> String {
        items.map { "- " + $0 }.joined(separator: "\n")
    }

    /// Each task becomes its own card, filling the page width instead of
    /// nesting a boxed list inside the digest.
    private var sessionGrid: some View {
        let blocks = presentation.taskGroups.flatMap(\.blocks)
        let columns = sessionColumnCount
        let rows = stride(from: 0, to: blocks.count, by: columns).map {
            Array(blocks[$0..<min($0 + columns, blocks.count)])
        }
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { block in
                        DayDigestTaskRow(block: block,
                                         collapsesDetails: presentation.collapsesDetails(of: block))
                            .padding(WorkspaceMetric.cardPadding)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(.quaternary.opacity(0.24),
                                        in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                            .overlay {
                                RoundedRectangle(cornerRadius: Brand.Radius.panel)
                                    .strokeBorder(Color.primary.opacity(0.09))
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sessionGridWidth = $0 }
    }

    private func digestSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.scaled(.subheadline).weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionList(_ blocks: [DayDigestPresentation.FocusBlock]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                focusBlock(block)
                    .padding(.vertical, 10)
                if block.id != blocks.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: Brand.Radius.control)
                .fill(.quaternary.opacity(0.24))
        }
    }

    private func focusBlock(_ block: DayDigestPresentation.FocusBlock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if block.timeRange != nil || block.title != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let timeRange = block.timeRange {
                        Text(timeRange)
                            .font(.scaled(.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let title = block.title {
                        Text(title)
                            .font(.scaled(.body).weight(.semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }
            if !block.summaryMarkdown.isEmpty {
                SelectableDigestText(block.summaryMarkdown)
                    .foregroundStyle(.secondary)
            }
            DayDigestSourceLinks(ids: block.sourceIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeAllocationDisclosure: some View {
        let total = presentation.timeAllocations.reduce(0) { $0 + $1.seconds }
        let segments = ProportionBarMath.segments(perApp: presentation.timeAllocations.map {
            (label: $0.app, seconds: $0.seconds)
        })
        return DisclosureGroup(isExpanded: $timeAllocationExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if total > 0 {
                    ProportionBar(segments: segments.map {
                        ($0, $0.label == "Other"
                            ? Color(nsColor: .tertiaryLabelColor)
                            : CaptureStyle.color(for: $0.label))
                    })
                    .padding(.vertical, 2)
                }
                ForEach(presentation.timeAllocations.prefix(12)) { allocation in
                    HStack(spacing: 8) {
                        StatusDot(color: CaptureStyle.color(for: allocation.app), size: 8)
                        Text(allocation.app).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(allocation.detail)
                            .font(allocation.seconds > 0
                                ? .scaled(.callout).monospacedDigit() : .scaled(.callout))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Label("Time allocation", systemImage: "chart.bar.xaxis")
                    .font(.scaled(.subheadline).weight(.semibold))
                Spacer()
                Text("Activity details")
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("dayDigest.timeAllocation")
        .accessibilityHint("Tracked app time shown as optional supporting detail")
    }
}

/// One task at a glance: status, title, and its next step. What was done
/// opens in place, so a day of tasks reads as a short list.
private struct DayDigestTaskRow: View {
    /// Status column width plus spacing; details and dividers align to it.
    static let textInset: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let block: DayDigestPresentation.FocusBlock
    /// See `DayDigestPresentation.collapsesDetails(of:)`.
    let collapsesDetails: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if collapsesDetails {
                Button {
                    withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) {
                        expanded.toggle()
                    }
                } label: {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hides what was done" : "Shows what was done")
                .accessibilityIdentifier("dayDigest.task.\(block.id)")

                if expanded {
                    details
                        .padding(.leading, Self.textInset)
                        .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            } else {
                header
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusMark
                .frame(width: Self.textInset - 8)
            VStack(alignment: .leading, spacing: 3) {
                if block.timeRange != nil || block.title != nil {
                    titleLine
                }
                if let nextStep = block.nextStep {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Next")
                            .font(DayDigestTaskType.summary.weight(.semibold))
                            .foregroundStyle(LBTokens.Palette.accentText)
                        Text(nextStep)
                            .font(DayDigestTaskType.summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !collapsesDetails {
                    details
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if collapsesDetails {
                Image(systemName: "chevron.right")
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let timeRange = block.timeRange {
                Text(timeRange)
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let title = block.title {
                Text(title)
                    .font(DayDigestTaskType.taskTitle)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var statusMark: some View {
        switch block.status {
        case .completed:
            statusSymbol("checkmark.circle.fill", LBTokens.Palette.success, label: "Done")
        case .inProgress:
            statusSymbol("circle.lefthalf.filled", LBTokens.Palette.accentText, label: "In progress")
        case .blocked:
            statusSymbol("exclamationmark.circle.fill", LBTokens.Palette.attention, label: "Blocked")
        case nil:
            Text("•")
                .font(DayDigestTaskType.taskTitle)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private func statusSymbol(_ name: String, _ color: Color, label: String) -> some View {
        Image(systemName: name)
            .font(DayDigestTaskType.taskTitle)
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var details: some View {
        if !block.summaryMarkdown.isEmpty {
            if collapsesDetails {
                SelectableDigestText(block.summaryMarkdown, font: DayDigestTaskType.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ExpandableDigestSummary(
                    text: block.summaryMarkdown,
                    accessibilityID: "dayDigest.taskShowMore.\(block.id)")
            }
        }
        DayDigestSourceLinks(ids: block.sourceIDs)
    }
}

/// Screen moments a legacy journal cited for a task.
private struct DayDigestSourceLinks: View {
    @EnvironmentObject private var app: AppState
    let ids: [Int64]

    var body: some View {
        ForEach(ids, id: \.self) { id in
            if let shot = app.activityStore.screenshot(id: id) {
                Button { app.openScreenSnapshot(id) } label: {
                    Label("\(shot.documentName.isEmpty ? shot.app : shot.documentName) · \(shot.ts.formatted(date: .omitted, time: .shortened))", systemImage: "doc.text.magnifyingglass")
                        .font(AppFont.scaled(.callout))
                }.buttonStyle(.workspaceLink)
            } else {
                Text("Source moment unavailable").font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExpandableDigestSummary: View {
    let text: String
    let accessibilityID: String
    @State private var expanded = false
    @State private var truncatedByLayout = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    private var showsControl: Bool {
        truncatedByLayout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableDigestText(text, font: DayDigestTaskType.summary)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : DayDigestTaskSummaryExpansion.collapsedLineLimit)
                .truncationMode(.tail)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: DigestSummaryCollapsedHeightKey.self,
                            value: geo.size.height)
                    }
                }
                .background(alignment: .top) { fullHeightProbe }
                .onPreferenceChange(DigestSummaryFullHeightKey.self) { fullHeight = $0 }
                .onPreferenceChange(DigestSummaryCollapsedHeightKey.self) { collapsedHeight = $0 }
                .onChange(of: fullHeight) { _, _ in refreshTruncation() }
                .onChange(of: collapsedHeight) { _, _ in refreshTruncation() }

            if showsControl {
                Button(expanded ? "Show less" : "Show more") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(AppFont.scaled(.body))
                .foregroundStyle(Brand.teal)
                .accessibilityHint(expanded
                    ? "Hides the extra task description"
                    : "Shows the rest of this task description")
                .accessibilityIdentifier(accessibilityID)
            }
        }
    }

    private var fullHeightProbe: some View {
        SelectableDigestText(text, font: DayDigestTaskType.summary)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: DigestSummaryFullHeightKey.self,
                        value: geo.size.height)
                }
            }
            .frame(height: 0, alignment: .top)
            .allowsHitTesting(false)
    }

    private func refreshTruncation() {
        guard !expanded else { return }
        truncatedByLayout = DayDigestTaskSummaryExpansion.hasRenderedOverflow(
            fullHeight: fullHeight,
            collapsedHeight: collapsedHeight)
    }
}

private struct DigestSummaryFullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DigestSummaryCollapsedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DayDigestActivityHourView: View {
    let group: DayDigestPresentation.ActivityHourGroup
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.entries) { entry in
                    DayDigestActivityEntryView(entry: entry)
                    if entry.id != group.entries.last?.id {
                        Divider().padding(.vertical, 7)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            HStack {
                Text(group.label)
                    .font(.scaled(.callout).weight(.medium).monospacedDigit())
                Spacer()
                Text("\(group.entries.count) event\(group.entries.count == 1 ? "" : "s")")
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("dayDigest.activityHour.\(group.id)")
    }
}

private struct DayDigestActivityEntryView: View {
    let entry: DayDigestPresentation.ActivityEntry
    @State private var evidenceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableDigestText(entry.headlineMarkdown)
            if !entry.evidenceMarkdown.isEmpty {
                DisclosureGroup(isExpanded: $evidenceExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.evidenceMarkdown.enumerated()), id: \.offset) { _, line in
                            SelectableDigestText("- " + line)
                                .font(.scaled(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Captured evidence · \(entry.evidenceMarkdown.count)")
                        .font(.scaled(.caption).weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("dayDigest.activityEvidence.\(entry.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
