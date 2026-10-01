import Foundation

extension DreamStore {
    /// Source writes and derived-memory revocation share one cross-process
    /// lock. Failure to persist revocation intent leaves the source untouched.
    func withMeetingEvidenceMutation<T>(for meetings: [Meeting], _ mutation: () throws -> T) throws -> T {
        try withSourceEvidenceMutation(on: meetings.map(\.startedAt),
                                       meetingIDs: Set(meetings.map(\.id)), mutation)
    }

    /// Screen, activity, and coding-agent evidence is read only for the
    /// dreamed day itself, never through another day's comparison window, so
    /// it revokes that day's reports and leaves meeting-derived facts alone.
    func withScreenEvidenceMutation<T>(on dates: [Date], _ mutation: () throws -> T) throws -> T {
        try withSourceEvidenceMutation(on: dates, meetingIDs: [], mutation)
    }

    private func withSourceEvidenceMutation<T>(
        on dates: [Date], meetingIDs: Set<UUID>, _ mutation: () throws -> T
    ) throws -> T {
        guard !dates.isEmpty || !meetingIDs.isEmpty else { return try mutation() }
        let calendar = Calendar.current
        let activityOnly = meetingIDs.isEmpty
        let reportKeys = DreamEvidenceInvalidation.dayKeys(
            affectedDays: dates, through: Date(), calendar: calendar,
            comparisonWindowDays: activityOnly ? 1 : DreamCompiler.comparisonWindowDays)
        return try withEvidenceMutation(
            affectedDayKeys: DreamEvidenceInvalidation.sourceDayKeys(for: dates),
            affectedMeetingIDs: meetingIDs, reportDayKeys: reportKeys,
            activityOnly: activityOnly, mutation)
    }
}

extension DreamEvidenceInvalidation {
    /// Provenance in older artifacts uses civil dates. Cover the adjacent UTC
    /// dates so changing the Mac's timezone cannot hide a screen dependency.
    /// This may retract a neighboring day's facts, which can be regenerated.
    static func sourceDayKeys(for dates: [Date]) -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return Set(dates.flatMap { date in
            (-2...2).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: date)
                    .map { DreamDay.key(for: $0, calendar: calendar) }
            }
        })
    }
}
