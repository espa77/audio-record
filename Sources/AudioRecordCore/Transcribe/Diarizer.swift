import FluidAudio
import Foundation

/// Who-spoke-when on one track, via FluidAudio's offline pipeline (pyannote community-1 style, Core ML).
public final class OfflineDiarizer {
    public let name = "FluidAudio offline diarizer (segmentation + WeSpeaker + VBx)"
    private let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())

    public init() {}

    public func prepare(status: @escaping (String) -> Void) async throws {
        status("Loading speaker model (downloads on first run)…")
        try await manager.prepareModels()
    }

    /// Returns segments sorted by start with labels normalised to SPEAKER_01, SPEAKER_02… by first appearance.
    public func diarize(samples16k: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerSegment] {
        guard ASRSupport.isWorthTranscribing(samples16k) else { return [] }
        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples16k) { done, total in
                progress(Double(done) / Double(max(total, 1)))
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
        let raw = result.segments
            .map { SpeakerSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        return Self.normaliseLabels(raw)
    }

    static func normaliseLabels(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        var map: [String: String] = [:]
        return segments.map { seg in
            if let l = map[seg.speaker] { return SpeakerSegment(speaker: l, start: seg.start, end: seg.end) }
            let label = String(format: "SPEAKER_%02d", map.count + 1)
            map[seg.speaker] = label
            return SpeakerSegment(speaker: label, start: seg.start, end: seg.end)
        }
    }
}
