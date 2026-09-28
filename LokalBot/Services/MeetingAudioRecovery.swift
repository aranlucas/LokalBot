import Foundation

/// One session-owned attachment loop. A bounded fast retry burst becomes a
/// low-frequency wait, never a permanent microphone-only failure.
@MainActor
final class MeetingAudioRecovery {
    typealias Candidate = MeetingDetector.DetectedApp
    private(set) var recordingID: UUID?
    private(set) var attempts = 0
    private(set) var intent: Meeting.CaptureIntent?
    private var task: Task<Void, Never>?
    private var attach: ((Candidate) -> Bool)?

    static func retryDelay(attempt: Int) -> TimeInterval {
        let delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15]
        return delays.indices.contains(attempt) ? delays[attempt] : 30
    }

    func start(recordingID: UUID, intent: Meeting.CaptureIntent,
               find: @escaping (Meeting.CaptureIntent) -> Candidate?,
               attach: @escaping (Candidate) -> Bool,
               sleep: @escaping (TimeInterval) async throws -> Void = {
                   try await Task.sleep(for: .seconds($0))
               }) {
        cancel()
        guard intent.systemAudioRequested else { return }
        self.recordingID = recordingID
        attempts = 0
        self.intent = intent
        self.attach = attach
        task = Task { [weak self] in
            while let self, self.recordingID == recordingID, !Task.isCancelled {
                do { try await sleep(Self.retryDelay(attempt: self.attempts)) } catch { return }
                guard self.recordingID == recordingID, !Task.isCancelled,
                      let intent = self.intent else { return }
                self.attempts += 1
                if let candidate = find(intent), self.offer(candidate, recordingID: recordingID) { return }
            }
        }
    }

    /// Detector/device events can wake recovery immediately, including after
    /// the initial burst. A stale generation or a different call cannot attach.
    @discardableResult
    func offer(_ app: Candidate, recordingID: UUID) -> Bool {
        guard self.recordingID == recordingID,
              intent?.accepts(appBundleID: app.bundleID, meetingURL: app.meetingURL) == true,
              attach?(app) == true else { return false }
        cancel()
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        recordingID = nil
        intent = nil
        attach = nil
    }
}

struct RecordingHealthReport: Codable {
    static let fileName = "recording-health.json"
    struct Event: Codable {
        var seconds: TimeInterval
        var messages: [String]
    }
    var version = 1
    var lastVerifiedCallAt: Date?
    var completedAt: Date?
    var events: [Event] = []
    var microphoneDroppedBuffers = 0
    var systemDroppedBuffers = 0
    var attachmentAttempts = 0
    var hadMissingAudio: Bool?
    var hadWriteFailure: Bool?

    var hasCaptureIssues: Bool {
        hadMissingAudio == true || hadWriteFailure == true
            || microphoneDroppedBuffers > 0 || systemDroppedBuffers > 0
    }

    static func load(in folder: URL) -> Self? {
        (try? Data(contentsOf: folder.appendingPathComponent(fileName)))
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    mutating func observe(_ messages: [String], seconds: TimeInterval) -> Bool {
        guard events.last?.messages != messages else { return false }
        // Keep the incident history bounded, preserving the first failure.
        if events.count >= 1_000 { events.remove(at: 1) }
        events.append(Event(seconds: max(0, seconds), messages: messages))
        return true
    }
}
