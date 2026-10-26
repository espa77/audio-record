import AVFoundation
import Foundation

public final class MicCapture {
    public typealias BufferHandler = (AVAudioPCMBuffer, UInt64) -> Void

    private var engine: AVAudioEngine?
    public private(set) var format: AVAudioFormat?
    public private(set) var deviceName: String = ""

    public init() {}

    /// Returns true when microphone access is granted (prompts on first use).
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts (or restarts, after a device change) a fresh engine on the current default input.
    public func start(handler: @escaping BufferHandler) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw AudioRecordError("No microphone input available (format \(fmt))")
        }
        format = fmt
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? ""
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, time in
            handler(buffer, time.hostTime)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        Log.capture.info("Mic running: \(fmt.sampleRate, privacy: .public) Hz, \(fmt.channelCount, privacy: .public) ch, device \(self.deviceName, privacy: .public)")
    }

    public func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
