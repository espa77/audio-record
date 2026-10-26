import AVFoundation
import Foundation

/// Streams any audio file as mono float32 at a target rate, chunk by chunk (no whole-file buffers).
final class MonoStream {
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let srcFormat: AVAudioFormat
    private let monoSrcFormat: AVAudioFormat
    private let dstFormat: AVAudioFormat
    private let channel: Int?               // nil = average all channels
    private var leadInFrames: Int
    private var exhausted = false
    private let chunk: AVAudioFrameCount = 32768

    /// - Parameters:
    ///   - channel: source channel to select; nil averages all channels.
    ///   - leadInSeconds: silence inserted before the first sample.
    init(url: URL, channel: Int?, sampleRate: Double, leadInSeconds: Double = 0) throws {
        file = try AVAudioFile(forReading: url)
        srcFormat = file.processingFormat
        self.channel = channel
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcFormat.sampleRate, channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AudioRecordError("Could not build mono formats for \(url.lastPathComponent)")
        }
        monoSrcFormat = mono
        dstFormat = dst
        converter = srcFormat.sampleRate == sampleRate ? nil : AVAudioConverter(from: mono, to: dst)
        leadInFrames = Int((leadInSeconds * sampleRate).rounded())
    }

    var isExhausted: Bool { exhausted && leadInFrames == 0 }

    /// Next chunk of mono samples at the target rate, or nil when finished.
    func next() throws -> [Float]? {
        if leadInFrames > 0 {
            let n = min(leadInFrames, Int(chunk))
            leadInFrames -= n
            return [Float](repeating: 0, count: n)
        }
        if exhausted { return nil }
        // AVAudioFile.read throws eofErr (-39) when asked to read at/after the end instead of
        // returning an empty buffer, and compressed files report their length approximately.
        let remaining = file.length - file.framePosition
        if remaining <= 0 { exhausted = true; return try flush() }
        let toRead = AVAudioFrameCount(min(Int64(chunk), remaining))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: toRead) else { return nil }
        do {
            try file.read(into: inBuf, frameCount: toRead)
        } catch {
            exhausted = true
            return try flush()
        }
        if inBuf.frameLength == 0 {
            exhausted = true
            return try flush()
        }
        let mono = downmix(inBuf)
        guard let converter else { return mono.samples }
        return try convert(mono, converter: converter, final: false)
    }

    private func flush() throws -> [Float]? {
        guard let converter else { return nil }
        guard let empty = AVAudioPCMBuffer(pcmFormat: monoSrcFormat, frameCapacity: 1) else { return nil }
        empty.frameLength = 0
        let tail = try convert(empty, converter: converter, final: true)
        return tail.isEmpty ? nil : tail
    }

    private func downmix(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let n = Int(buf.frameLength)
        let out = AVAudioPCMBuffer(pcmFormat: monoSrcFormat, frameCapacity: AVAudioFrameCount(n))!
        out.frameLength = AVAudioFrameCount(n)
        let dst = out.floatChannelData![0]
        let channels = Int(buf.format.channelCount)
        if let src = buf.floatChannelData {
            if let channel, channel < channels {
                dst.update(from: src[channel], count: n)
            } else {
                for i in 0..<n { dst[i] = 0 }
                for c in 0..<channels { let s = src[c]; for i in 0..<n { dst[i] += s[i] } }
                let scale = 1 / Float(channels)
                for i in 0..<n { dst[i] *= scale }
            }
        } else if let src = buf.int16ChannelData {
            let scale = 1 / Float(Int16.max)
            for i in 0..<n {
                var acc: Float = 0
                if let channel, channel < channels { acc = Float(src[channel][i]) }
                else { for c in 0..<channels { acc += Float(src[c][i]) }; acc /= Float(channels) }
                dst[i] = acc * scale
            }
        }
        return out
    }

    private func convert(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, final: Bool) throws -> [Float] {
        let ratio = dstFormat.sampleRate / monoSrcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(max(input.frameLength, 1)) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else { return [] }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if final { outStatus.pointee = .endOfStream; return nil }
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return input
        }
        if let error { throw error }
        if status == .error { throw AudioRecordError("Sample-rate conversion failed") }
        return out.samples
    }
}

extension AVAudioPCMBuffer {
    var samples: [Float] {
        guard let data = floatChannelData, frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(frameLength)))
    }
}

public enum AudioMixdown {
    /// Writes a 2-channel AAC file: left = mic track, right = system track, each resampled to `sampleRate`.
    public static func writeStereoM4A(mic: URL, micLeadIn: Double, sys: URL, sysLeadIn: Double,
                                      to url: URL, sampleRate: Double = 48_000) throws {
        let micStream = try MonoStream(url: mic, channel: nil, sampleRate: sampleRate, leadInSeconds: micLeadIn)
        let sysStream = try MonoStream(url: sys, channel: nil, sampleRate: sampleRate, leadInSeconds: sysLeadIn)
        guard let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw AudioRecordError("Could not build stereo format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        try? FileManager.default.removeItem(at: url)
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        var left: [Float] = [], right: [Float] = []
        var leftDone = false, rightDone = false
        while true {
            if left.count < 32768, !leftDone { if let c = try micStream.next() { left += c } else { leftDone = true } }
            if right.count < 32768, !rightDone { if let c = try sysStream.next() { right += c } else { rightDone = true } }
            let n = (leftDone && rightDone) ? max(left.count, right.count) : min(left.count, right.count)
            if n == 0 { if leftDone && rightDone { break } else { continue } }
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<n {
                l[i] = i < left.count ? left[i] : 0
                r[i] = i < right.count ? right[i] : 0
            }
            try out.write(from: buf)
            left.removeFirst(min(n, left.count))
            right.removeFirst(min(n, right.count))
            if leftDone && rightDone && left.isEmpty && right.isEmpty { break }
        }
    }
}

public enum AudioLoader {
    /// Whole file (or one channel of it) as 16 kHz mono float32 — the format every model here expects.
    public static func loadMono16k(url: URL, channel: Int? = nil) throws -> [Float] {
        let stream = try MonoStream(url: url, channel: channel, sampleRate: 16_000)
        var all: [Float] = []
        while let c = try stream.next() { all += c }
        return all
    }

    public static func durationSeconds(url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// RMS in dBFS of a sample array (−∞ → -120 when silent); handy for "did we capture anything" checks.
    public static func rmsDB(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var acc: Double = 0
        for s in samples { acc += Double(s * s) }
        let rms = (acc / Double(samples.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }
}
