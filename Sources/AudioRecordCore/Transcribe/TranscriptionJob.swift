import Foundation

public struct TranscriptionInput {
    public var audioURL: URL                 // the file that ends up in the meeting folder
    public var micTrackURL: URL?             // lossless mic track if still present
    public var sysTrackURL: URL?             // lossless system track if still present
    public var startedAt: Date
    public var timestamp: String
    /// How to read `audioURL` when the lossless tracks are gone.
    public var layout: Layout

    public enum Layout {
        case stereoMicSystem     // our own recordings: L = mic, R = system
        case monoEverything      // an arbitrary file: everything is "system", fully diarized
    }

    public init(audioURL: URL, micTrackURL: URL? = nil, sysTrackURL: URL? = nil,
                startedAt: Date, timestamp: String, layout: Layout) {
        self.audioURL = audioURL; self.micTrackURL = micTrackURL; self.sysTrackURL = sysTrackURL
        self.startedAt = startedAt; self.timestamp = timestamp; self.layout = layout
    }

    /// Builds an input for a finished recording in the output root.
    public static func forRecording(_ r: RecordingResult) -> TranscriptionInput {
        let fm = FileManager.default
        return TranscriptionInput(
            audioURL: r.audioURL,
            micTrackURL: fm.fileExists(atPath: r.micTrackURL.path) ? r.micTrackURL : nil,
            sysTrackURL: fm.fileExists(atPath: r.sysTrackURL.path) ? r.sysTrackURL : nil,
            startedAt: r.startedAt, timestamp: r.timestamp, layout: .stereoMicSystem)
    }

    /// Builds an input for any audio file (CLI, deferred recordings). Stamp from the name when possible.
    public static func forFile(_ url: URL, settings: Settings) throws -> TranscriptionInput {
        let stem = url.deletingPathExtension().lastPathComponent
        let date = Timestamps.date(fromFileStamp: stem)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let stamp = Timestamps.date(fromFileStamp: stem) != nil ? stem : Timestamps.fileStamp(date)
        let work = settings.inProgressDir.appendingPathComponent(stamp, isDirectory: true)
        let mic = work.appendingPathComponent("mic.caf"), sys = work.appendingPathComponent("sys.caf")
        let fm = FileManager.default
        let channels = (try? AudioLoader.channelCount(url: url)) ?? 1
        return TranscriptionInput(
            audioURL: url,
            micTrackURL: fm.fileExists(atPath: mic.path) ? mic : nil,
            sysTrackURL: fm.fileExists(atPath: sys.path) ? sys : nil,
            startedAt: date, timestamp: stamp,
            layout: channels == 2 ? .stereoMicSystem : .monoEverything)
    }
}

public struct TranscriptionOutput {
    public var folderURL: URL
    public var markdownURL: URL
    public var audioURL: URL
    public var turns: [Turn]
    public var identities: [SpeakerIdentity]
    public var markdown: String
    public var seconds: [String: Double]     // stage timings
}

/// Orchestrates: load tracks → diarize system track → transcribe both → attribute → names → markdown → folder.
public final class TranscriptionJob {
    public let settings: Settings
    public let engine: ASREngine
    public let diarizer: OfflineDiarizer
    public let llm: LLMClient?
    /// When set, the meeting folder is created here instead of next to the audio file's parent.
    public var outputRoot: URL?

    public init(settings: Settings, engine: ASREngine, diarizer: OfflineDiarizer = OfflineDiarizer(), llm: LLMClient?) {
        self.settings = settings; self.engine = engine; self.diarizer = diarizer; self.llm = llm
    }

    public func run(_ input: TranscriptionInput, progress: @escaping (PipelineProgress) -> Void) async throws -> TranscriptionOutput {
        var timings: [String: Double] = [:]
        func timed<T>(_ key: String, _ body: () async throws -> T) async rethrows -> T {
            let t0 = Date(); defer { timings[key] = Date().timeIntervalSince(t0) }
            return try await body()
        }

        progress(PipelineProgress(stage: "Loading audio", fraction: 0.02))
        let (micSamples, sysSamples) = try await timed("load") { try loadTracks(input) }
        let duration = Double(max(micSamples.count, sysSamples.count)) / 16_000

        progress(PipelineProgress(stage: "Preparing models", fraction: 0.05))
        try await timed("models") {
            try await engine.prepare { progress(PipelineProgress(stage: $0, fraction: 0.05)) }
            try await diarizer.prepare { progress(PipelineProgress(stage: $0, fraction: 0.08)) }
        }

        progress(PipelineProgress(stage: "Identifying speakers", fraction: 0.10))
        let segments = try await timed("diarize") {
            try await diarizer.diarize(samples16k: sysSamples) { f in
                progress(PipelineProgress(stage: "Identifying speakers", fraction: 0.10 + 0.25 * f))
            }
        }

        progress(PipelineProgress(stage: "Transcribing other participants", fraction: 0.40))
        let sysWords = try await timed("asr.system") { try await engine.transcribe(samples16k: sysSamples) }
        progress(PipelineProgress(stage: "Transcribing microphone", fraction: 0.65))
        let micWords = try await timed("asr.mic") { try await engine.transcribe(samples16k: micSamples) }

        progress(PipelineProgress(stage: "Assembling transcript", fraction: 0.80))
        let sysTurns = Attribution.turns(from: Attribution.assign(words: sysWords, segments: segments))
        let micTurns = Attribution.micTurns(words: micWords)
        let turns = Attribution.merge(micTurns, sysTurns)
        let labels = Attribution.labelsInOrder(turns)

        progress(PipelineProgress(stage: "Resolving names", fraction: 0.85))
        let identities = await timed("names") {
            await NameResolver.resolve(turns: turns, labels: labels, myName: settings.myName, llm: llm) {
                progress(PipelineProgress(stage: $0, fraction: 0.86))
            }
        }

        progress(PipelineProgress(stage: "Writing files", fraction: 0.95))
        let folder = (outputRoot ?? input.audioURL.deletingLastPathComponent())
            .appendingPathComponent("\(input.timestamp)_meeting", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioDest = folder.appendingPathComponent(input.audioURL.lastPathComponent)
        if input.audioURL != audioDest {
            if fm.fileExists(atPath: audioDest.path) { try fm.removeItem(at: audioDest) }
            try fm.moveItem(at: input.audioURL, to: audioDest)
        }
        let provenance = "Transcribed locally: \(engine.name); speakers: \(diarizer.name)" +
            (llm.map { "; names: \($0.describe)" } ?? "; names: pattern matching only") +
            (engine.vocabularyNote.map { "; \($0)" } ?? "")
        let info = MeetingInfo(startedAt: input.startedAt, duration: duration,
                               audioFileName: audioDest.lastPathComponent, provenance: provenance)
        let markdown = MarkdownWriter.render(meeting: info, turns: turns, identities: identities)
        let mdURL = folder.appendingPathComponent("\(input.timestamp).md")
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        if !settings.keepLosslessTracks, let mic = input.micTrackURL {
            try? fm.removeItem(at: mic.deletingLastPathComponent())
        }
        progress(PipelineProgress(stage: "Done", fraction: 1))
        return TranscriptionOutput(folderURL: folder, markdownURL: mdURL, audioURL: audioDest,
                                   turns: turns, identities: identities, markdown: markdown, seconds: timings)
    }

    private func loadTracks(_ input: TranscriptionInput) throws -> (mic: [Float], sys: [Float]) {
        if let m = input.micTrackURL, let s = input.sysTrackURL {
            return (try AudioLoader.loadMono16k(url: m), try AudioLoader.loadMono16k(url: s))
        }
        switch input.layout {
        case .stereoMicSystem:
            return (try AudioLoader.loadMono16k(url: input.audioURL, channel: 0),
                    try AudioLoader.loadMono16k(url: input.audioURL, channel: 1))
        case .monoEverything:
            return ([], try AudioLoader.loadMono16k(url: input.audioURL))
        }
    }
}

extension AudioLoader {
    public static func channelCount(url: URL) throws -> Int {
        Int(try AVAudioFileChannels.count(url))
    }
}

import AVFoundation
enum AVAudioFileChannels {
    static func count(_ url: URL) throws -> AVAudioChannelCount {
        try AVAudioFile(forReading: url).fileFormat.channelCount
    }
}
