import Accelerate
import AVFoundation
import Foundation

/// Recent microphone loudness for the recording HUD. The writer records one
/// value per captured buffer; the HUD reads the latest few at display rate.
/// The bars therefore move with the voice and stay flat while the microphone
/// is silent or reconnecting.
final class AudioLevelMeter: @unchecked Sendable {
    static let historyLength = 32
    private let lock = NSLock()
    private var levels: [Float] = []

    func reset() {
        lock.lock()
        levels.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func record(_ level: Float) {
        lock.lock()
        levels.append(min(max(level, 0), 1))
        if levels.count > Self.historyLength { levels.removeFirst(levels.count - Self.historyLength) }
        lock.unlock()
    }

    /// The newest `count` levels, oldest first, padded with silence.
    func recent(_ count: Int) -> [Float] {
        lock.lock()
        let tail = Array(levels.suffix(count))
        lock.unlock()
        return Array(repeating: 0, count: max(0, count - tail.count)) + tail
    }

    /// 0 at -55 dBFS (room noise), 1 at -10 dBFS (loud speech).
    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 55) / 45, 0), 1)
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var total: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            var value: Float = 0
            vDSP_rmsqv(channels[channel], 1, &value, vDSP_Length(buffer.frameLength))
            total += value * value
        }
        return channelCount > 0 ? sqrt(total / Float(channelCount)) : 0
    }
}
