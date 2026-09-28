import SwiftUI

enum TimelineBrowseMode: String, CaseIterable, Identifiable {
    case day = "Day", rewind = "Rewind"
    var id: String { rawValue }
}

struct TimelineMomentsSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let mode: TimelineBrowseMode
    let query: String
    let application: String
    let onOpenContext: () -> Void
    @State private var textMatches: Set<Int64> = []
    @State private var searching = false
    @State private var textRevision = 0

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var filtered: [ActivityStore.Screenshot] {
        model.shots.filter { shot in
            (application.isEmpty || shot.app == application)
                && (needle.isEmpty || [shot.app, shot.windowTitle, shot.documentName]
                    .contains { $0.localizedCaseInsensitiveContains(needle) } || textMatches.contains(shot.id))
        }.sorted { $0.ts < $1.ts }
    }

    var body: some View {
        let moments = filtered
        let groups = Dictionary(grouping: moments) { Calendar.current.dateInterval(of: .hour, for: $0.ts)!.start }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Retained Moments").font(.headline)
                Spacer()
                Text("\(moments.count) of \(model.shots.count)").font(.callout).foregroundStyle(.secondary)
            }
            if searching { LoadingStateLabel("Searching retained text…") }
            if mode == .rewind {
                ScreenRewindView(frames: ScreenRewindSequence.frames(from: moments),
                                 selectedSnapshotID: $model.selectedSnapshotID,
                                 onReload: { model.reload(app: app) })
            }
            if moments.isEmpty {
                Text(needle.isEmpty && application.isEmpty ? "No retained moments for this day." : "No moments match these filters.")
                    .font(.body).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groups.keys.sorted(), id: \.self) { hour in
                    Text(hour.formatted(.dateTime.hour().minute())).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(groups[hour] ?? []) { shot in
                        momentRow(shot)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.moments")
        .onReceive(NotificationCenter.default.publisher(for: .retainedScreenTextChanged)) { _ in
            textMatches = []
            textRevision &+= 1
        }
        .task(id: "\(model.day)|\(needle)|\(model.shots.map(\.id))|\(textRevision)") {
            textMatches = []
            guard !needle.isEmpty else { searching = false; return }
            searching = true
            let search = needle, ids = model.shots.map(\.id)
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let matches = await ActivityStore.readInBackground(at: app.activityStore.databaseURL) { store in
                store.matchingSnapshotIDs(ids, query: search)
            }
            guard !Task.isCancelled else { return }
            textMatches = matches
            searching = false
        }
    }

    private func momentRow(_ shot: ActivityStore.Screenshot) -> some View {
        Button {
            model.showsRawCapture = false
            model.selection = nil
            model.selectedSessionID = nil
            app.selectedMeetingIDs = []
            model.selectedSnapshotID = shot.id
            onOpenContext()
        } label: {
            HStack(spacing: 12) {
                ScreenThumbnailView(screenshot: shot, height: 56).frame(width: 90)
                VStack(alignment: .leading, spacing: 5) {
                    Text(shot.documentName.isEmpty ? (shot.windowTitle.isEmpty ? shot.app : shot.windowTitle) : shot.documentName)
                        .font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text("\(shot.app) · \(shot.ts.formatted(date: .omitted, time: .standard))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if shot.isBookmarked { Image(systemName: "bookmark.fill").foregroundStyle(Brand.teal) }
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(12).lbGroupedSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timeline.moment.\(shot.id)")
    }
}
