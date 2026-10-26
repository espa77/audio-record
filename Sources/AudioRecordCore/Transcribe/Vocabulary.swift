import Foundation

/// One entry of the domain vocabulary (`Resources/vocabulary.txt`).
public struct VocabularyTerm: Equatable, Sendable {
    public let text: String
    public let aliases: [String]
    public init(text: String, aliases: [String] = []) { self.text = text; self.aliases = aliases }

    /// Single words with at least one lowercase letter are corrected acoustically by the Parakeet
    /// path. Phrases and acronyms only serve as hints: a phrase makes the rescorer swallow its
    /// neighbours, an acronym (PANSS, COWS) collides with ordinary words.
    public var isBoostable: Bool {
        !text.contains(where: { $0.isWhitespace }) && text.count >= 4 && text.contains(where: { $0.isLowercase })
    }
}

/// Domain terms both ASR engines are biased towards. The list ships with the repo as
/// `Resources/vocabulary.txt`; `scripts/build-app.sh` copies it into the app bundle.
public struct Vocabulary: Sendable {
    public static let fileName = "vocabulary.txt"
    public static let empty = Vocabulary(terms: [], sourceURL: nil)

    public let terms: [VocabularyTerm]
    public let sourceURL: URL?

    public init(terms: [VocabularyTerm], sourceURL: URL?) { self.terms = terms; self.sourceURL = sourceURL }

    public var isEmpty: Bool { terms.isEmpty }
    /// Canonical texts plus aliases (what Apple Speech receives as contextual strings).
    public var allStrings: [String] { terms.flatMap { [$0.text] + $0.aliases } }
    /// Terms the Parakeet CTC spotter is allowed to correct.
    public var boostable: [VocabularyTerm] { terms.filter(\.isBoostable) }

    /// Text format: one term per line, optional `term: alias, alias`, `#` comments, blank lines
    /// ignored. Case-insensitive duplicates keep the first occurrence.
    public static func parse(_ contents: String) -> [VocabularyTerm] {
        var seen = Set<String>()
        var out: [VocabularyTerm] = []
        for raw in contents.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var text = line
            var aliases: [String] = []
            if let colon = line.firstIndex(of: ":") {
                text = line[..<colon].trimmingCharacters(in: .whitespaces)
                aliases = line[line.index(after: colon)...].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            out.append(VocabularyTerm(text: text, aliases: aliases))
        }
        return out
    }

    public static func load(url: URL) throws -> Vocabulary {
        Vocabulary(terms: parse(try String(contentsOf: url, encoding: .utf8)), sourceURL: url)
    }

    /// App: `Contents/Resources/vocabulary.txt`. CLI/self-test built from a checkout: the repo file.
    public static func locate() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent(fileName)) }
        let root = URL(fileURLWithPath: #filePath)   // <root>/Sources/AudioRecordCore/Transcribe/Vocabulary.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent("Resources").appendingPathComponent(fileName))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The bundled list, or empty (logged) when missing or unreadable.
    public static func bundled() -> Vocabulary {
        guard let url = locate() else { Log.pipeline.warning("vocabulary.txt not found"); return .empty }
        do { return try load(url: url) } catch {
            Log.pipeline.error("vocabulary.txt unreadable: \(error.localizedDescription)")
            return .empty
        }
    }
}

/// A correction proposed by the CTC rescorer: `original` is the span as the ASR wrote it
/// (one or more words), `score` the term's acoustic score over that span.
public struct VocabularyReplacement: Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let score: Float
    public init(original: String, replacement: String, score: Float) {
        self.original = original; self.replacement = replacement; self.score = score
    }
}

/// Applies rescorer corrections to the timed word list under our own gate: a correction must
/// beat `minScore` (measured: spoken terms score > 1.8, mishearings of other words < 1.5),
/// replaces exactly the span it was proposed for, keeps that span's time, trailing punctuation
/// and sentence-initial capital.
public enum VocabularyApplier {
    public static let defaultMinScore: Float = 1.5
    public static var minScore: Float {
        ProcessInfo.processInfo.environment["AUDIORECORD_VOCAB_MIN_SCORE"].flatMap(Float.init) ?? defaultMinScore
    }
    static let punctuation: Set<Character> = [".", ",", ";", ":", "?", "!"]

    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    public static func apply(words: [Word], replacements: [VocabularyReplacement], minScore: Float = minScore)
        -> (words: [Word], applied: [String])
    {
        var words = words
        var used = [Bool](repeating: false, count: words.count)
        var applied: [String] = []
        for r in replacements where r.score >= minScore {
            let origKeys = r.original.split(whereSeparator: { $0.isWhitespace }).map { key(String($0)) }.filter { !$0.isEmpty }
            var tokens = r.replacement.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !origKeys.isEmpty, !tokens.isEmpty, words.count >= origKeys.count else { continue }
            var found: Int? = nil
            for i in 0...(words.count - origKeys.count) {
                var ok = true
                for k in 0..<origKeys.count where used[i + k] || key(words[i + k].text) != origKeys[k] { ok = false; break }
                if ok { found = i; break }
            }
            guard let i = found else { continue }
            let span = Array(words[i..<(i + origKeys.count)])
            if let last = span.last?.text.last, punctuation.contains(last),
               !(tokens[tokens.count - 1].last.map { punctuation.contains($0) } ?? false) {
                tokens[tokens.count - 1] += String(last)
            }
            let sentenceStart = i == 0 || (words[i - 1].text.last.map { ".?!".contains($0) } ?? false)
            if sentenceStart, let first = span.first?.text.first, first.isUppercase, tokens[0].first?.isLowercase == true {
                tokens[0] = tokens[0].prefix(1).uppercased() + tokens[0].dropFirst()
            }
            let confidence = span.map(\.confidence).min() ?? 1
            var replacementWords: [Word] = []
            if tokens.count == span.count {
                for (k, t) in tokens.enumerated() {
                    replacementWords.append(Word(text: t, start: span[k].start, end: span[k].end, confidence: confidence))
                }
            } else {
                let start = span[0].start, end = max(span[span.count - 1].end, start + 0.05)
                let step = (end - start) / Double(tokens.count)
                for (k, t) in tokens.enumerated() {
                    let s = k == 0 ? start : start + Double(k) * step
                    let e = k == tokens.count - 1 ? end : start + Double(k + 1) * step
                    replacementWords.append(Word(text: t, start: s, end: e, confidence: confidence))
                }
            }
            words.replaceSubrange(i..<(i + span.count), with: replacementWords)
            used.replaceSubrange(i..<(i + span.count), with: [Bool](repeating: true, count: replacementWords.count))
            if !applied.contains(r.replacement) { applied.append(r.replacement) }
        }
        return (words, applied)
    }

    /// Spelling-only fix for single-token terms: a word whose letters and digits equal a term's
    /// (`pHQ9` vs `PHQ-9`, `DSM5` vs `DSM-5`) takes the canonical spelling. Case-only differences
    /// are left alone, so `Sertraline` at a sentence start and the word `cows` stay as written.
    public static func normalize(words: [Word], vocabulary: Vocabulary) -> [Word] {
        var canonical: [String: String] = [:]
        for s in vocabulary.allStrings where !s.contains(where: { $0.isWhitespace }) {
            let k = key(s)
            if canonical[k] == nil { canonical[k] = s }
        }
        guard !canonical.isEmpty else { return words }
        return words.map { w in
            var core = w.text
            var trailing = ""
            while let last = core.last, punctuation.contains(last) { trailing.insert(last, at: trailing.startIndex); core.removeLast() }
            guard let c = canonical[key(core)], c.lowercased() != core.lowercased() else { return w }
            var fixed = w
            fixed.text = c + trailing
            return fixed
        }
    }
}
