import Foundation

/// Pure functions: words + diarization segments → speaker-labelled turns.
public enum Attribution {
    /// Assigns each word the speaker whose segment overlaps it most; falls back to the nearest
    /// segment within `maxDistance`, then to the previous word's speaker.
    public static func assign(words: [Word], segments: [SpeakerSegment], maxDistance: Double = 1.0) -> [(word: Word, speaker: String)] {
        guard !segments.isEmpty else { return words.map { ($0, "SPEAKER_01") } }
        let segs = segments.sorted { $0.start < $1.start }
        var out: [(Word, String)] = []
        out.reserveCapacity(words.count)
        var cursor = 0
        var previous: String? = nil
        for w in words {
            // advance cursor past segments that end well before this word
            while cursor < segs.count - 1, segs[cursor].end < w.start - maxDistance { cursor += 1 }
            var best: String? = nil
            var bestOverlap = 0.0
            var nearest: String? = nil
            var nearestDist = Double.infinity
            var i = cursor
            let mid = (w.start + w.end) / 2
            while i < segs.count, segs[i].start <= w.end + maxDistance {
                let s = segs[i]
                let overlap = min(s.end, w.end) - max(s.start, w.start)
                if overlap > bestOverlap { bestOverlap = overlap; best = s.speaker }
                let dist = mid < s.start ? s.start - mid : (mid > s.end ? mid - s.end : 0)
                if dist < nearestDist { nearestDist = dist; nearest = s.speaker }
                i += 1
            }
            let speaker = best ?? (nearestDist <= maxDistance ? nearest : nil) ?? previous ?? segs[min(cursor, segs.count - 1)].speaker
            out.append((w, speaker))
            previous = speaker
        }
        return out
    }

    /// Groups consecutive same-speaker words into turns; a new turn starts on speaker change
    /// or when the silence between two words exceeds `maxGap`.
    public static func turns(from assigned: [(word: Word, speaker: String)], maxGap: Double = 1.5) -> [Turn] {
        var turns: [Turn] = []
        for (w, s) in assigned {
            if var last = turns.last, last.speaker == s, w.start - last.end <= maxGap {
                last.text += " " + w.text
                last.end = max(last.end, w.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speaker: s, start: w.start, end: w.end, text: w.text))
            }
        }
        return turns.map { t in
            var c = t
            c.text = c.text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            return c
        }
    }

    /// Mic words all belong to one speaker; split into turns on long pauses.
    public static func micTurns(words: [Word], label: String = micLabel, maxGap: Double = 2.0) -> [Turn] {
        turns(from: words.map { ($0, label) }, maxGap: maxGap)
    }

    public static func merge(_ lists: [Turn]...) -> [Turn] {
        lists.flatMap { $0 }.sorted { a, b in a.start == b.start ? a.end < b.end : a.start < b.start }
    }

    /// Labels in order of first appearance.
    public static func labelsInOrder(_ turns: [Turn]) -> [String] {
        var seen: [String] = []
        for t in turns where !seen.contains(t.speaker) { seen.append(t.speaker) }
        return seen
    }
}
