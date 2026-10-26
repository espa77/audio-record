import Foundation

public struct Word: Codable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float
    public init(text: String, start: Double, end: Double, confidence: Float = 1) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

public struct SpeakerSegment: Codable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker; self.start = start; self.end = end
    }
}

/// One contiguous utterance by one speaker label.
public struct Turn: Codable, Equatable {
    public var speaker: String      // label such as "mic" or "SPEAKER_01"
    public var start: Double
    public var end: Double
    public var text: String
    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }
}

public enum IdentitySource: Equatable, Codable {
    case configured
    case inferred(evidence: String)
    case unresolved
}

public struct SpeakerIdentity: Equatable, Codable {
    public var label: String
    public var name: String
    public var source: IdentitySource
    public init(label: String, name: String, source: IdentitySource) {
        self.label = label; self.name = name; self.source = source
    }
}

public struct PipelineProgress: Equatable {
    public var stage: String
    public var fraction: Double      // 0…1 overall
    public init(stage: String, fraction: Double) { self.stage = stage; self.fraction = fraction }
}

public let micLabel = "mic"
