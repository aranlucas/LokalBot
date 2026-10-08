import AVFoundation
import CoreMedia
import Foundation

/// Dictation's microphone: an `AVCaptureSession` on the default input device.
///
/// `AVAudioEngine` stops itself whenever the I/O hardware format changes, and
/// a Bluetooth headset changes format as soon as its microphone opens (AirPods
/// switch from music to headset mode). The engine therefore stopped right after
/// it started; rebuilding it a second later had already released the
/// microphone, so the headset fell back to music mode and the next start
/// repeated the cycle. Dictation kept recording fragments while the microphone
/// indicator flickered. A capture session keeps the device open across those
/// format changes and converts every buffer to one fixed client format, so a
/// headset switch never reaches the writer.
///
/// Starting and stopping run on a private serial queue: opening a Bluetooth
/// microphone can take a second, and the main thread also services the global
/// dictation shortcut's keyboard event tap.
final class CaptureSessionMicrophoneInput: NSObject, MicrophoneInput,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Every instance starts and stops on this one queue, so a new session
    /// cannot open the device while an earlier one is still closing.
    private static let sessionQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.dictation-microphone.session", qos: .userInitiated)

    /// Speech recognition runs at 16 kHz mono, so dictation records exactly that.
    static let clientFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private enum RunState {
        case stopped
        case starting
        case running
        case failed
    }

    let inputFormat: AVAudioFormat = CaptureSessionMicrophoneInput.clientFormat
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let deliveryQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.dictation-microphone.delivery", qos: .userInteractive)
    private let deviceName: String
    private let lock = NSLock()
    private var block: AVAudioNodeTapBlock?
    private var state: RunState = .stopped
    private var runtimeErrorObserver: NSObjectProtocol?

    init(device: AVCaptureDevice? = AVCaptureDevice.default(for: .audio)) throws {
        guard let device else { throw MicRecorder.RecorderError.inputUnavailable }
        let deviceInput = try AVCaptureDeviceInput(device: device)
        deviceName = device.localizedName
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(deviceInput) else {
            throw MicRecorder.RecorderError.inputUnavailable
        }
        session.addInput(deviceInput)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.clientFormat.sampleRate,
            AVNumberOfChannelsKey: Int(Self.clientFormat.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: deliveryQueue)
        guard session.canAddOutput(output) else {
            throw MicRecorder.RecorderError.unsupportedInputFormat
        }
        session.addOutput(output)
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [deviceName] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            lokalbotLog(
                "dictation microphone session error device=\(deviceName): "
                    + (error?.localizedDescription ?? "unknown"))
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        Self.sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// True from `start()` until the session fails or is stopped. A session
    /// that is still opening counts as running so health checks do not tear
    /// down a Bluetooth microphone that is mid-switch.
    var isRunning: Bool {
        lock.lock()
        let state = self.state
        lock.unlock()
        switch state {
        case .starting: return true
        case .running: return session.isRunning
        case .stopped, .failed: return false
        }
    }

    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        lock.lock()
        self.block = block
        lock.unlock()
    }

    func removeTap() {
        lock.lock()
        block = nil
        lock.unlock()
    }

    func start() throws {
        lock.lock()
        guard state == .stopped || state == .failed else {
            lock.unlock()
            return
        }
        state = .starting
        lock.unlock()
        let opened = ContinuousClock.now
        Self.sessionQueue.async { [self] in
            session.startRunning()
            let running = session.isRunning
            lock.lock()
            if state == .starting { state = running ? .running : .failed }
            lock.unlock()
            let elapsed = opened.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            lokalbotLog(
                "dictation microphone \(running ? "opened" : "FAILED to open") device=\(deviceName) "
                    + "after=\(milliseconds)ms")
        }
    }

    func stop() {
        lock.lock()
        let wasActive = state != .stopped
        state = .stopped
        lock.unlock()
        guard wasActive else { return }
        Self.sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let block = self.block
        lock.unlock()
        guard let block, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        block(buffer, audioTime(for: sampleBuffer))
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int(Int32.max),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: description) else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// The buffer's start on the host clock, like an `AVAudioEngine` tap.
    private func audioTime(for sampleBuffer: CMSampleBuffer) -> AVAudioTime {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if presentation.isValid, let clock = session.synchronizationClock {
            let host = CMSyncConvertTime(presentation, from: clock, to: CMClockGetHostTimeClock())
            if host.isValid, host.seconds > 0 {
                return AVAudioTime(hostTime: CMClockConvertHostTimeToSystemUnits(host))
            }
        }
        return AVAudioTime(hostTime: mach_absolute_time())
    }
}
