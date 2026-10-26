import AVFoundation
import Foundation

/// Serialised float32 CAF writer for one capture source. Remembers the host time of its first
/// buffer, converts buffers whose format changed after a capture restart, and pads the track
/// with silence when the clock says audio is missing (capture stalled, then recovered), so both
/// tracks stay aligned to wall-clock time.
public final class TrackWriter {
    public let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    public private(set) var firstHostTime: UInt64?
    public private(set) var frames: Int64 = 0
    public private(set) var sampleRate: Double = 0
    public private(set) var lastWriteAt: Date?
    public private(set) var paddedSeconds: Double = 0
    /// Holes shorter than this are clock jitter, not missing audio.
    public static let padThreshold: Double = 1.0

    public init(url: URL) { self.url = url }

    public func open(format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        lock.lock(); defer { lock.unlock() }
        file = f
        sampleRate = format.sampleRate
    }

    public func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        if firstHostTime == nil, hostTime > 0 { firstHostTime = hostTime }
        lastWriteAt = Date()
        do {
            if let first = firstHostTime, hostTime > first {
                let expected = (HostClock.seconds(hostTime) - HostClock.seconds(first)) * sampleRate
                let hole = expected - Double(frames)
                if hole > Self.padThreshold * sampleRate, hole < 6 * 3600 * sampleRate {
                    try pad(frames: AVAudioFrameCount(hole), into: file)
                }
            }
            let out = try converted(buffer, to: file.processingFormat)
            try file.write(from: out)
            frames += Int64(out.frameLength)
        } catch {
            Log.capture.error("write failed for \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil
        converter = nil
    }

    public var seconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    private func pad(frames count: AVAudioFrameCount, into file: AVAudioFile) throws {
        let fmt = file.processingFormat
        var remaining = count
        while remaining > 0 {
            let n = min(remaining, 65_536)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
            buf.frameLength = n
            for b in UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList) {
                if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
            }
            try file.write(from: buf)
            frames += Int64(n)
            remaining -= n
        }
        paddedSeconds += Double(count) / sampleRate
        Log.capture.warning("\(self.url.lastPathComponent, privacy: .public): padded \(Double(count) / self.sampleRate, privacy: .public)s of missing audio")
    }

    private func converted(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { throw AudioRecordError("no converter from \(buffer.format) to \(format)") }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AudioRecordError("buffer") }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error { throw error }
        return out
    }
}
