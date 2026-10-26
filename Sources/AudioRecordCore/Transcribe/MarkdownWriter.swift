import Foundation

public struct MeetingInfo {
    public var startedAt: Date
    public var duration: Double
    public var audioFileName: String
    public var provenance: String      // engines used
    public init(startedAt: Date, duration: Double, audioFileName: String, provenance: String) {
        self.startedAt = startedAt; self.duration = duration; self.audioFileName = audioFileName; self.provenance = provenance
    }
}

public enum MarkdownWriter {
    public static func render(meeting: MeetingInfo, turns: [Turn], identities: [SpeakerIdentity]) -> String {
        let names = Dictionary(uniqueKeysWithValues: identities.map { ($0.label, $0.name) })
        var md = "# Meeting \(Timestamps.heading(meeting.startedAt))\n\n"
        md += "| | |\n|---|---|\n"
        md += "| Started | \(Timestamps.full(meeting.startedAt)) |\n"
        md += "| Duration | \(Timestamps.duration(meeting.duration)) |\n"
        md += "| Audio | \(meeting.audioFileName) |\n"
        md += "| Speakers | \(identities.map(\.name).joined(separator: ", ")) |\n\n"
        md += "## Transcript\n\n"
        if turns.isEmpty {
            md += "_No speech detected._\n\n"
        }
        for t in turns {
            let who = names[t.speaker] ?? t.speaker
            md += "**\(who)** [\(Timestamps.clock(t.start))]\n\(t.text)\n\n"
        }
        md += "## Speaker map\n\n| Label | Name | Source |\n|---|---|---|\n"
        for id in identities {
            let source: String
            switch id.source {
            case .configured: source = "configured (microphone)"
            case .inferred(let evidence): source = "inferred: \(evidence.replacingOccurrences(of: "|", with: "/"))"
            case .unresolved: source = "not identified"
            }
            md += "| \(id.label) | \(id.name) | \(source) |\n"
        }
        md += "\n_\(meeting.provenance)_\n"
        return md
    }
}
