import AVFoundation
import Foundation

/// Where microphone PCM comes from. Only the input is swappable; the
/// recorder's writer, preview tee, recovery journal, and health stay real.
protocol MicrophoneInput: AnyObject {
    var inputFormat: AVAudioFormat { get }
    var isRunning: Bool { get }
    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock)
    func removeTap()
    func start() throws
    func stop()
}

/// Today's microphone: a fresh `AVAudioEngine` input node.
final class EngineMicrophoneInput: MicrophoneInput {
    let engine = AVAudioEngine()

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    var isRunning: Bool { engine.isRunning }

    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        // Let AVAudioEngine choose the current hardware format (see MicRecorder).
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: block)
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }
}

#if LOKALBOT_TEST_HOOKS
/// Plays an audio file into the recorder in real time ÷ `speed`, then
/// silence until stopped.
final class FileMicrophoneInput: MicrophoneInput {
    private let file: AVAudioFile
    private let speed: Double
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.file-microphone")
    private var timer: DispatchSourceTimer?
    private var block: AVAudioNodeTapBlock?
    private var bufferSize: AVAudioFrameCount = 4_096

    init(url: URL, speed: Double = 1) throws {
        file = try AVAudioFile(forReading: url)
        self.speed = max(0.1, speed)
    }

    var inputFormat: AVAudioFormat { file.processingFormat }
    var isRunning: Bool { timer != nil }

    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        queue.sync {
            self.bufferSize = bufferSize
            self.block = block
        }
    }

    func removeTap() { queue.sync { block = nil } }

    func start() throws {
        let interval = Double(bufferSize) / file.processingFormat.sampleRate / speed
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.deliver() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func deliver() {
        guard let block,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufferSize) else { return }
        do {
            try file.read(into: buffer, frameCount: bufferSize)
        } catch {
            buffer.frameLength = 0
        }
        if buffer.frameLength == 0 { // silence after the file ends
            buffer.frameLength = bufferSize
            for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
        }
        block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
    }
}
#endif
