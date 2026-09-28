import XCTest
@testable import LokalBot

final class TimelineMomentSearchTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    func testRefreshPreservesMatchesButRejectsOlderCompletion() {
        let first = request(shots: 1), refresh = request(shots: 2)
        var state = TimelineMomentSearchResults()
        state.begin(first)
        state.finish(first, matches: [11, 22])
        state.begin(refresh)
        XCTAssertEqual(state.matches(for: refresh), [11, 22])
        XCTAssertTrue(state.isSearching)
        state.finish(first, matches: [99])
        XCTAssertEqual(state.matches(for: refresh), [11, 22])
        XCTAssertTrue(state.isSearching)
        state.finish(refresh, matches: [11, 22, 33])
        XCTAssertEqual(state.matches(for: refresh), [11, 22, 33])
        XCTAssertFalse(state.isSearching)
    }

    func testQueryDayAndRetentionChangesImmediatelyHidePreviousMatches() {
        let first = request()
        for changed in [request(query: "other"), request(text: 1),
                        TimelineMomentSearchRequest(day: day.addingTimeInterval(86_400), query: "alpha",
                                                    shotsRevision: 0, textRevision: 0)] {
            var state = TimelineMomentSearchResults()
            state.begin(first)
            state.finish(first, matches: [11])
            // A changed scope must hide results even before SwiftUI starts its task.
            XCTAssertTrue(state.matches(for: changed).isEmpty)
            state.begin(changed)
            XCTAssertTrue(state.matches(for: changed).isEmpty)
            state.finish(first, matches: [11])
            XCTAssertTrue(state.matches(for: changed).isEmpty)
        }
    }

    func testRetentionInvalidationRejectsAnInFlightCompletion() {
        let first = request()
        var state = TimelineMomentSearchResults()
        state.begin(first)
        state.finish(first, matches: [11])
        state.invalidate()
        state.finish(first, matches: [11])
        XCTAssertTrue(state.matches(for: first).isEmpty)
    }

    @MainActor
    func testChangedCaptureMetadataRefreshesAvailableApplicationsWithoutChangingIDs() {
        let model = CaptureModel()
        model.shots = [.init(id: 1, ts: day, path: "", app: "Xcode"),
                       .init(id: 2, ts: day, path: "", app: "Xcode")]
        let revision = model.shotsRevision
        XCTAssertEqual(model.momentApplications, ["Xcode"])
        model.shots = [.init(id: 1, ts: day, path: "", app: "Safari")]
        XCTAssertGreaterThan(model.shotsRevision, revision)
        XCTAssertEqual(model.momentApplications, ["Safari"])
    }

    private func request(query: String = "alpha", shots: Int = 0, text: Int = 0) -> TimelineMomentSearchRequest {
        TimelineMomentSearchRequest(day: day, query: query, shotsRevision: shots, textRevision: text)
    }
}
