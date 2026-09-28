import SwiftUI

struct RecordingHealthStrip: View {
    @ObservedObject var recording: RecordingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let health = recording.memoryHealthSnapshot(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        Label("Mic · \(health.microphoneStatus)", systemImage: "mic")
                        Label("System · \(health.systemAudioStatus)", systemImage: "speaker.wave.2")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Mic · \(health.microphoneStatus)", systemImage: "mic")
                        Label("System · \(health.systemAudioStatus)", systemImage: "speaker.wave.2")
                    }
                }
                if let recovery = health.lastRecoveryAt {
                    Text("Last recovery \(recovery.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .lbGroupedSurface()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("recording.health")
        }
    }
}
