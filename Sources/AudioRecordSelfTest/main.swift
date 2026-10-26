import AVFoundation
import AudioRecordCore
import Foundation

// Minimal self-test harness: the Command Line Tools toolchain has no XCTest / swift-testing.
// Run: swift run -c release audiorecord-selftest

var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \((file as NSString).lastPathComponent):\(line): \(message)")
    }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    expect(a == b, "\(message) expected \(b), got \(a)", file: file, line: line)
}
func w(_ t: String, _ s: Double, _ e: Double) -> Word { Word(text: t, start: s, end: e) }

// MARK: Attribution

do {
    let segs = [SpeakerSegment(speaker: "SPEAKER_01", start: 0, end: 2),
                SpeakerSegment(speaker: "SPEAKER_02", start: 2.5, end: 5)]
    // "there": more overlap with S1; "gap": no overlap, nearest is S2; "far": too far from any → previous speaker
    let words = [w("hi", 0.1, 0.5), w("there", 1.8, 2.6), w("gap", 2.2, 2.4), w("far", 9, 9.5)]
    let a = Attribution.assign(words: words, segments: segs)
    expectEqual(a.map(\.speaker), ["SPEAKER_01", "SPEAKER_01", "SPEAKER_02", "SPEAKER_02"], "overlap/nearest/previous")
    let b = Attribution.assign(words: [w("x", 2.6, 2.9)], segments: segs)
    expectEqual(b.first?.speaker, "SPEAKER_02", "inside second segment")
    expectEqual(Attribution.assign(words: [w("x", 0, 1)], segments: []).first?.speaker, "SPEAKER_01", "no segments")

    let assigned: [(word: Word, speaker: String)] = [
        (w("a", 0, 0.3), "S1"), (w("b", 0.4, 0.6), "S1"), (w("c", 0.7, 1.0), "S2"),
        (w("d", 1.1, 1.3), "S2"), (w("e", 4.0, 4.2), "S2"),
    ]
    let turns = Attribution.turns(from: assigned, maxGap: 1.5)
    expectEqual(turns.map(\.text), ["a b", "c d", "e"], "turn grouping")
    expectEqual(turns.map(\.speaker), ["S1", "S2", "S2"], "turn speakers")
    expectEqual(turns[1].start, 0.7); expectEqual(turns[1].end, 1.3)

    let mic = Attribution.micTurns(words: [w("me", 1.0, 1.5)])
    let sys = [Turn(speaker: "SPEAKER_01", start: 0.2, end: 0.9, text: "them"),
               Turn(speaker: "SPEAKER_02", start: 2, end: 3, text: "other")]
    let merged = Attribution.merge(mic, sys)
    expectEqual(merged.map(\.speaker), ["SPEAKER_01", micLabel, "SPEAKER_02"], "merge order")
    expectEqual(Attribution.labelsInOrder(merged), ["SPEAKER_01", micLabel, "SPEAKER_02"], "labels order")
}

// MARK: Timestamps / markdown / settings

do {
    let d = Timestamps.date(fromFileStamp: "2026-10-26_14-30-05")!
    expectEqual(Timestamps.fileStamp(d), "2026-10-26_14-30-05")
    expectEqual(Timestamps.heading(d), "2026-10-26 14:30")
    expectEqual(Timestamps.full(d), "2026-10-26 14:30:05")
    expectEqual(Timestamps.clock(3661.9), "01:01:01")
    expectEqual(Timestamps.duration(2712), "45:12")
    expectEqual(Timestamps.duration(3725), "1:02:05")
    expect(Timestamps.date(fromFileStamp: "notes") == nil, "non-stamp name")

    let info = MeetingInfo(startedAt: d, duration: 2712, audioFileName: "2026-10-26_14-30-05.m4a", provenance: "test")
    let turns = [Turn(speaker: micLabel, start: 3, end: 5, text: "Hi everyone."),
                 Turn(speaker: "SPEAKER_01", start: 10, end: 12, text: "This is Bob.")]
    let ids = [SpeakerIdentity(label: micLabel, name: "Ethan", source: .configured),
               SpeakerIdentity(label: "SPEAKER_01", name: "Bob", source: .inferred(evidence: "This is Bob")),
               SpeakerIdentity(label: "SPEAKER_02", name: "person_1", source: .unresolved)]
    let md = MarkdownWriter.render(meeting: info, turns: turns, identities: ids)
    expect(md.hasPrefix("# Meeting 2026-10-26 14:30\n"), "heading")
    expect(md.contains("| Duration | 45:12 |"), "duration row")
    expect(md.contains("| Speakers | Ethan, Bob, person_1 |"), "speakers row")
    expect(md.contains("**Ethan** [00:00:03]\nHi everyone.\n"), "mic turn")
    expect(md.contains("**Bob** [00:00:10]\nThis is Bob.\n"), "named turn")
    expect(md.contains("| SPEAKER_01 | Bob | inferred: This is Bob |"), "speaker map inferred")
    expect(md.contains("| SPEAKER_02 | person_1 | not identified |"), "speaker map unresolved")

    var s = Settings.defaults
    s.myName = "Test"
    let back = try! JSONDecoder().decode(Settings.self, from: try! JSONEncoder().encode(s))
    expectEqual(back, s, "settings round trip")
    expectEqual(back.outputRoot.lastPathComponent, "Meetings")
}

// MARK: Name resolution (async)

final class FakeLLM: LLMClient {
    let describe = "fake"
    let reply: String
    init(_ reply: String) { self.reply = reply }
    func complete(system: String, user: String) async throws -> String { reply }
}
final class BrokenLLM: LLMClient {
    let describe = "broken"
    func complete(system: String, user: String) async throws -> String { throw AudioRecordError("down") }
}

let turns = [
    Turn(speaker: micLabel, start: 0, end: 3, text: "Hi everyone, thanks for joining."),
    Turn(speaker: "SPEAKER_01", start: 4, end: 8, text: "Thanks Ethan. This is Daniel from the platform team."),
    Turn(speaker: "SPEAKER_02", start: 9, end: 12, text: "Hi all, Karen here. Quick question for Daniel."),
    Turn(speaker: micLabel, start: 13, end: 16, text: "Moira, can you share the status?"),
    Turn(speaker: "SPEAKER_03", start: 17, end: 20, text: "Sure. The migration is on track."),
    Turn(speaker: "SPEAKER_04", start: 21, end: 24, text: "One more thing before we close."),
]
let labels = [micLabel, "SPEAKER_01", "SPEAKER_02", "SPEAKER_03", "SPEAKER_04"]

let done = DispatchSemaphore(value: 0)
Task {
    let a = await NameResolver.resolve(turns: turns, labels: labels, myName: "Ethan", llm: nil)
    expectEqual(a.map(\.name), ["Ethan", "Daniel", "Karen", "person_1", "person_2"], "heuristics only")
    expectEqual(a[0].source, .configured)
    if case .inferred = a[1].source {} else { expect(false, "Daniel should be inferred") }
    expectEqual(a[3].source, .unresolved)

    let reply = """
    Here you go: ```json
    {"SPEAKER_01": {"name": "Daniel", "confidence": 0.95, "evidence": "This is Daniel"},
     "SPEAKER_03": {"name": "Moira", "confidence": 0.8, "evidence": "Moira, can you share"},
     "SPEAKER_04": {"name": "Zebulon", "confidence": 0.99, "evidence": "made up"},
     "SPEAKER_02": {"name": "Karen", "confidence": 0.3, "evidence": "weak"}}
    ```
    """
    let b = await NameResolver.resolve(turns: turns, labels: labels, myName: "Ethan", llm: FakeLLM(reply))
    expectEqual(b.map(\.name), ["Ethan", "Daniel", "Karen", "Moira", "person_1"], "LLM validated against transcript")

    let c = await NameResolver.resolve(turns: turns, labels: labels, myName: "Ethan", llm: BrokenLLM())
    expectEqual(c.map(\.name), ["Ethan", "Daniel", "Karen", "person_1", "person_2"], "LLM failure falls back")

    let d = await NameResolver.resolve(turns: turns, labels: [micLabel], myName: "", llm: nil)
    expectEqual(d.first?.name, "Me", "empty name")
    done.signal()
}
done.wait()

// MARK: Track writer: silence padding after a stall, format conversion after a device change

do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audiorecord-selftest-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let fmt16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let fmt48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    func tone(_ fmt: AVAudioFormat, frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(fmt.channelCount) { for i in 0..<frames { b.floatChannelData![ch][i] = 0.5 } }
        return b
    }
    let writer = TrackWriter(url: tmp)
    try! writer.open(format: fmt16)
    let t0 = mach_absolute_time()
    writer.write(tone(fmt16, frames: 8000), hostTime: t0)
    writer.write(tone(fmt16, frames: 8000), hostTime: t0 + HostClock.hostTime(seconds: 0.5))
    expectEqual(writer.frames, 16000, "contiguous buffers are not padded")
    writer.write(tone(fmt16, frames: 8000), hostTime: t0 + HostClock.hostTime(seconds: 4.0))
    expectEqual(writer.frames, 72000, "a 3 s hole is padded with silence before the next buffer")
    expect(abs(writer.paddedSeconds - 3.0) < 0.01, "padded seconds reported (\(writer.paddedSeconds))")
    writer.write(tone(fmt48, frames: 4800), hostTime: t0 + HostClock.hostTime(seconds: 4.5))
    // The rate converter keeps a few hundred frames of look-ahead until the next buffer arrives.
    expect(writer.frames > 73600 - 512 && writer.frames <= 73600, "48 kHz stereo buffer converted into the 16 kHz mono track (\(writer.frames))")
    writer.close()
    let back = try! AVAudioFile(forReading: tmp)
    expectEqual(back.length, writer.frames, "file length matches frames written")
    expect(back.processingFormat.sampleRate == 16_000 && back.processingFormat.channelCount == 1, "track format unchanged")
}

// MARK: Vocabulary + retiming + settings upgrade

do {
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    let parsed = Vocabulary.parse("""
    # comment
    sertraline

    Seroquel: quetiapine XR, seroquel xr
      PHQ-9  
    SERTRALINE
    """)
    expectEqual(parsed.count, 3, "comments, blanks and duplicates dropped")
    expectEqual(parsed[1].text, "Seroquel")
    expectEqual(parsed[1].aliases, ["quetiapine XR", "seroquel xr"])
    expectEqual(parsed[2].text, "PHQ-9", "trimmed")
    let bundled = Vocabulary.bundled()
    expect(bundled.terms.count > 300, "bundled list found (\(bundled.terms.count) terms)")
    expect(bundled.allStrings.contains("quetiapine"), "bundled list has drug names")

    expect(bundled.boostable.count > 250 && bundled.boostable.count < bundled.terms.count, "phrases/acronyms are hint-only")
    expect(!VocabularyTerm(text: "PHQ-9").isBoostable && !VocabularyTerm(text: "tardive dyskinesia").isBoostable
           && VocabularyTerm(text: "sertraline").isBoostable && VocabularyTerm(text: "Stevens-Johnson").isBoostable, "boostable rule")

    let old = [w("Certralein", 0, 0.5), w("and", 0.5, 0.6), w("fluoxidine,", 0.6, 1.4), w("Venla", 1.4, 1.7),
               w("vaccine", 1.7, 2.2), w("program", 2.2, 2.6)]
    let props = [VocabularyReplacement(original: "Certralein", replacement: "sertraline", score: 2.0),
                 VocabularyReplacement(original: "fluoxidine,", replacement: "fluoxetine", score: 4.6),
                 VocabularyReplacement(original: "Venla vaccine", replacement: "venlafaxine", score: 3.1),
                 VocabularyReplacement(original: "program", replacement: "micrograms", score: 1.31),
                 VocabularyReplacement(original: "nothing here", replacement: "topiramate", score: 9)]
    let out = VocabularyApplier.apply(words: old, replacements: props, minScore: 1.5)
    expectEqual(out.words.map(\.text), ["Sertraline", "and", "fluoxetine,", "venlafaxine", "program"], "gate, punctuation, capital kept")
    expectEqual(out.applied, ["sertraline", "fluoxetine", "venlafaxine"])
    expect(near(out.words[2].start, 0.6) && near(out.words[2].end, 1.4), "single-word replacement keeps its span")
    expect(near(out.words[3].start, 1.4) && near(out.words[3].end, 2.2), "two words merged into one term cover both")
    expectEqual(VocabularyApplier.apply(words: old, replacements: [], minScore: 1.5).words, old, "no proposals, no change")

    let vocab = Vocabulary(terms: [VocabularyTerm(text: "PHQ-9"), VocabularyTerm(text: "COWS"), VocabularyTerm(text: "sertraline")], sourceURL: nil)
    let norm = VocabularyApplier.normalize(words: [w("pHQ9", 0, 1), w("cows.", 1, 2), w("Sertraline", 2, 3), w("phq9?", 3, 4)], vocabulary: vocab)
    expectEqual(norm.map(\.text), ["PHQ-9", "cows.", "Sertraline", "PHQ-9?"], "spelling normalised, case-only differences untouched")

    let legacy = """
    {"outputRoot":"file:///tmp/x/","myName":"T","asrEngine":"parakeetUltra","llmEndpoint":"http://localhost:1234/v1/chat/completions","llmModel":"","llmEnabled":true,"keepLosslessTracks":false}
    """
    let decoded = try? JSONDecoder().decode(Settings.self, from: legacy.data(using: .utf8)!)
    expect(decoded?.vocabularyEnabled == true, "settings saved before vocabularyEnabled existed still decode, vocabulary on")
    expectEqual(decoded?.myName, "T")
    var s = Settings.defaults
    s.vocabularyEnabled = false
    let back = try! JSONDecoder().decode(Settings.self, from: try! JSONEncoder().encode(s))
    expectEqual(back.vocabularyEnabled, false, "vocabularyEnabled round trip")
}

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
