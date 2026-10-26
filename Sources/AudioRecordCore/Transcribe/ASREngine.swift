import AVFoundation
import FluidAudio
import Foundation

public protocol ASREngine: AnyObject {
    var name: String { get }
    /// Downloads/loads models when needed. Safe to call repeatedly.
    func prepare(status: @escaping (String) -> Void) async throws
    /// 16 kHz mono samples → words with timestamps (seconds from the start of `samples`).
    func transcribe(samples16k: [Float]) async throws -> [Word]
    /// How the domain vocabulary was used, for the transcript footer (nil when none is active).
    var vocabularyNote: String? { get }
}

extension ASREngine {
    public var vocabularyNote: String? { nil }
}

public enum ASRSupport {
    /// Tracks with (near) nothing on them are skipped: saves time and avoids model errors on empty input.
    public static func isWorthTranscribing(_ samples: [Float]) -> Bool {
        samples.count >= 16_000 && AudioLoader.rmsDB(samples) > -70
    }
}

// MARK: - FluidAudio / Parakeet

public final class ParakeetASR: ASREngine {
    public let version: AsrModelVersion
    public let vocabulary: Vocabulary
    private var manager: AsrManager?
    private var boosting: VocabularyBoostingSession?
    private var appliedTerms: [String] = []

    public init(version: AsrModelVersion = .ultra, vocabulary: Vocabulary = .empty) {
        self.version = version
        self.vocabulary = vocabulary
    }

    public var vocabularyNote: String? {
        guard !vocabulary.isEmpty else { return nil }
        var seen = Set<String>()
        let applied = appliedTerms.filter { seen.insert($0).inserted }
        return "vocabulary: \(vocabulary.boostable.count) of \(vocabulary.terms.count) terms correctable, "
            + (applied.isEmpty ? "none applied" : "applied: " + applied.joined(separator: ", "))
    }

    public var name: String {
        switch version {
        case .ultra: return "Parakeet Ultra (FluidAudio 0.17.7)"
        case .v3: return "Parakeet TDT 0.6B v3 (FluidAudio 0.17.7)"
        case .v2: return "Parakeet TDT 0.6B v2 (FluidAudio 0.17.7)"
        default: return "Parakeet \(version) (FluidAudio 0.17.7)"
        }
    }

    public func prepare(status: @escaping (String) -> Void) async throws {
        if manager == nil {
            status("Loading speech model (downloads on first run)…")
            let models = try await AsrModels.downloadAndLoad(version: version)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
        }
        if boosting == nil, !vocabulary.isEmpty {
            // FluidAudio custom vocabulary: separate 110M CTC encoder spots the terms, a rescorer rewrites them.
            status("Loading vocabulary model (downloads on first run)…")
            let ctc = try await CtcModels.downloadAndLoad()
            let terms = vocabulary.boostable.map {
                CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
            }
            if terms.isEmpty { return }
            boosting = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctc)
        }
    }

    public func transcribe(samples16k: [Float]) async throws -> [Word] {
        guard let manager else { throw AudioRecordError("ASR models not loaded") }
        guard ASRSupport.isWorthTranscribing(samples16k) else { return [] }
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples16k, decoderState: &state)
        if let timings = result.tokenTimings, !timings.isEmpty {
            let words = buildWordTimings(from: timings).compactMap { w -> Word? in
                let t = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                return Word(text: t, start: w.startTime, end: max(w.endTime, w.startTime + 0.05), confidence: result.confidence)
            }
            let normalized = VocabularyApplier.normalize(words: words, vocabulary: vocabulary)
            guard let boosting,
                  let out = await boosting.rescore(text: result.text, tokenTimings: timings, audioSamples: samples16k)
            else { return normalized }
            // The rescorer proposes spans; we apply them ourselves under a stricter acoustic gate.
            let proposals = out.replacements.filter { $0.shouldReplace }.compactMap { r -> VocabularyReplacement? in
                guard let rep = r.replacementWord, let score = r.replacementScore else { return nil }
                return VocabularyReplacement(original: r.originalWord, replacement: rep, score: score)
            }
            if ProcessInfo.processInfo.environment["AUDIORECORD_VOCAB_DEBUG"] != nil {
                for r in out.replacements {
                    let line = String(format: "vocab %@ %@ → %@ | orig %.2f repl %.2f | %@\n", r.shouldReplace ? "propose" : "skip   ",
                                      r.originalWord, r.replacementWord ?? "-", r.originalScore, r.replacementScore ?? 0, r.reason)
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                }
            }
            let applied = VocabularyApplier.apply(words: normalized, replacements: proposals)
            appliedTerms += applied.applied
            return applied.words
        }
        // No timings (unexpected): spread the words evenly so attribution still works.
        let tokens = result.text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let dur = Double(samples16k.count) / 16_000
        let step = dur / Double(tokens.count)
        return tokens.enumerated().map { i, t in
            Word(text: t, start: Double(i) * step, end: Double(i + 1) * step, confidence: result.confidence)
        }
    }
}

// MARK: - Apple Speech (macOS 26+)

#if canImport(Speech)
import Speech

@available(macOS 26, *)
public final class AppleSpeechASR: ASREngine {
    public let name = "Apple SpeechAnalyzer (built-in)"
    public let vocabulary: Vocabulary
    private let requestedLocale: Locale
    private var locale: Locale?

    public init(locale: Locale = Locale(identifier: "en_US"), vocabulary: Vocabulary = .empty) {
        self.requestedLocale = locale
        self.vocabulary = vocabulary
    }

    public var vocabularyNote: String? {
        vocabulary.isEmpty ? nil : "vocabulary: \(vocabulary.terms.count) terms as contextual strings"
    }

    public func prepare(status: @escaping (String) -> Void) async throws {
        if locale != nil { return }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AudioRecordError("Apple Speech does not support locale \(requestedLocale.identifier)")
        }
        let probe = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            status("Downloading Apple Speech assets for \(supported.identifier)…")
            try await request.downloadAndInstall()
        }
        locale = supported
    }

    public func transcribe(samples16k: [Float]) async throws -> [Word] {
        guard let locale else { throw AudioRecordError("Apple Speech not prepared") }
        guard ASRSupport.isWorthTranscribing(samples16k) else { return [] }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audiorecord-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try AudioLoader.writeWav16k(samples16k, to: tmp)
        let file = try AVAudioFile(forReading: tmp)

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary.allStrings
            try await analyzer.setContext(context)
        }
        let collector = Task<[Word], Error> {
            var words: [Word] = []
            for try await result in transcriber.results {
                let text = result.text
                for run in text.runs {
                    let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !piece.isEmpty, let range = run.audioTimeRange else { continue }
                    let start = range.start.seconds, end = range.end.seconds
                    let parts = piece.split(separator: " ").map(String.init)
                    let step = (end - start) / Double(max(parts.count, 1))
                    for (i, p) in parts.enumerated() {
                        words.append(Word(text: p, start: start + Double(i) * step, end: start + Double(i + 1) * step))
                    }
                }
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let words = try await collector.value.sorted { $0.start < $1.start }
        return VocabularyApplier.normalize(words: words, vocabulary: vocabulary)
    }
}
#endif

extension AudioLoader {
    public static func writeWav16k(_ samples: [Float], to url: URL) throws {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw AudioRecordError("format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            try file.write(from: buf)
            i += n
        }
    }
}
