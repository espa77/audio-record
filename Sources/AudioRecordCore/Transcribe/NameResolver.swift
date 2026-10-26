import Foundation

/// Maps anonymous speaker labels to real names when the conversation gives them away,
/// via a local LLM first and self-introduction patterns as a fallback.
public enum NameResolver {
    public struct Candidate: Equatable {
        public var name: String
        public var confidence: Double
        public var evidence: String
    }

    static let minConfidence = 0.7
    static let maxPromptChars = 60_000

    /// Final identities for every label in `labels` (order = first appearance).
    public static func resolve(turns: [Turn], labels: [String], myName: String,
                               llm: LLMClient?, status: ((String) -> Void)? = nil) async -> [SpeakerIdentity] {
        let unknown = labels.filter { $0 != micLabel }
        var candidates: [String: Candidate] = [:]

        if !unknown.isEmpty, let llm {
            status?("Resolving speaker names with \(llm.describe)…")
            let (system, user) = buildPrompt(turns: turns, unknownLabels: unknown, myName: myName)
            do {
                let reply = try await llm.complete(system: system, user: user)
                candidates = parse(reply, labels: unknown, transcript: turns)
            } catch {
                Log.pipeline.error("name resolution via LLM failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for (label, c) in heuristics(turns: turns, labels: unknown, myName: myName)
        where (candidates[label]?.confidence ?? 0) < minConfidence {
            candidates[label] = c
        }

        var person = 0
        return labels.map { label in
            if label == micLabel {
                return SpeakerIdentity(label: label, name: myName.isEmpty ? "Me" : myName, source: .configured)
            }
            if let c = candidates[label], c.confidence >= minConfidence {
                return SpeakerIdentity(label: label, name: c.name, source: .inferred(evidence: c.evidence))
            }
            person += 1
            return SpeakerIdentity(label: label, name: "person_\(person)", source: .unresolved)
        }
    }

    // MARK: Prompt

    static func renderTranscript(_ turns: [Turn], myName: String, limit: Int) -> String {
        let lines = turns.map { t -> String in
            let who = t.speaker == micLabel ? "\(myName) (microphone, known)" : t.speaker
            return "[\(Timestamps.clock(t.start))] \(who): \(t.text)"
        }
        let full = lines.joined(separator: "\n")
        if full.count <= limit { return full }
        // Keep the opening (introductions), every line that looks like it names someone, and the close.
        let head = lines.prefix(while: { _ in true }).reduce(into: (text: "", count: 0)) { acc, l in
            if acc.count + l.count < limit / 2 { acc.text += l + "\n"; acc.count += l.count + 1 }
        }.text
        let cueRegex = try! NSRegularExpression(pattern: #"\b(this is|i'm|i am|my name is|here is|thanks|thank you|hi|hello|hey)\b[^.!?]{0,40}\b[A-Z][a-z]{2,}"#, options: [.caseInsensitive])
        var middle = ""
        for l in lines.dropFirst(head.split(separator: "\n").count) {
            if cueRegex.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil, middle.count < limit / 3 {
                middle += l + "\n"
            }
        }
        let tail = lines.suffix(20).joined(separator: "\n")
        return head + "…\n" + middle + "…\n" + tail
    }

    static func buildPrompt(turns: [Turn], unknownLabels: [String], myName: String) -> (system: String, user: String) {
        let system = """
        You identify meeting participants from a transcript. Speakers are labelled SPEAKER_01, SPEAKER_02, … \
        Determine each labelled speaker's real name ONLY when the transcript gives clear evidence: \
        they introduce themselves ("this is Daniel", "Karen here", "my name is …"), or another participant \
        addresses them by name and they are clearly the one replying. Never guess from topic or role. \
        The microphone speaker is already known and must not be assigned to any label. \
        Reply with JSON only: an object whose keys are the labels and whose values are \
        {"name": string or null, "confidence": number 0-1, "evidence": short quote from the transcript}. \
        Use null and confidence 0 when unsure.
        """
        let user = """
        Labels to resolve: \(unknownLabels.joined(separator: ", ")).
        Known: the microphone speaker is \(myName).

        Transcript:
        \(renderTranscript(turns, myName: myName, limit: maxPromptChars))
        """
        return (system, user)
    }

    // MARK: Parsing / validation

    static func parse(_ reply: String, labels: [String], transcript: [Turn]) -> [String: Candidate] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else { return [:] }
        let jsonText = String(reply[start...end])
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let words = Set(transcript.flatMap { $0.text.split { !$0.isLetter && $0 != "'" && $0 != "-" } }.map { $0.lowercased() })
        var out: [String: Candidate] = [:]
        for label in labels {
            guard let entry = obj[label] as? [String: Any] else { continue }
            guard let rawName = entry["name"] as? String else { continue }
            let name = cleanName(rawName)
            guard !name.isEmpty else { continue }
            let confidence = (entry["confidence"] as? Double) ?? ((entry["confidence"] as? NSNumber)?.doubleValue ?? 0)
            let evidence = (entry["evidence"] as? String) ?? ""
            // Every token of the name must literally occur in the transcript: no invented names.
            let tokens = name.split(separator: " ").map { $0.lowercased() }
            guard tokens.allSatisfy({ words.contains($0) }) else { continue }
            out[label] = Candidate(name: name, confidence: confidence, evidence: evidence)
        }
        return out
    }

    static func cleanName(_ raw: String) -> String {
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: " '-"))
        let cleaned = raw.unicodeScalars.filter { allowed.contains($0) }.map { Character($0) }
        let parts = String(cleaned).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard (1...3).contains(parts.count) else { return "" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Heuristic fallback (self-introductions only)

    // Trigger phrase is case-insensitive; the captured name must be capitalised (ASR output capitalises proper nouns).
    static let introRegex = try! NSRegularExpression(
        pattern: #"(?i:(?:^|[.!?,]\s*)(?:hi|hello|hey|good (?:morning|afternoon|evening))?[,.]?\s*(?:everyone|all|team|folks)?[,.]?\s*(?:this is|it's|it is|i'm|i am|my name is|here is)\s+)([A-Z][a-z]+(?:\s[A-Z][a-z]+)?)\b"#,
        options: [])
    static let secondTokenStoplist: Set<String> = ["From", "And", "Here", "With", "The", "Of", "On", "In", "At", "To", "For",
                                                   "But", "So", "Speaking", "Calling", "Again", "Today", "Just", "Also"]
    static let hereRegex = try! NSRegularExpression(pattern: #"\b([A-Z][a-z]{2,})\s+here\b"#)

    static func heuristics(turns: [Turn], labels: [String], myName: String) -> [String: Candidate] {
        var out: [String: Candidate] = [:]
        for t in turns where labels.contains(t.speaker) && out[t.speaker] == nil {
            let head = String(t.text.prefix(160))
            let range = NSRange(head.startIndex..., in: head)
            var found: String? = nil
            if let m = introRegex.firstMatch(in: head, range: range), let r = Range(m.range(at: 1), in: head) {
                found = String(head[r])
            } else if let m = hereRegex.firstMatch(in: head, range: range), let r = Range(m.range(at: 1), in: head) {
                found = String(head[r])
            }
            if var name = found.map(cleanName), !name.isEmpty {
                var parts = name.split(separator: " ").map(String.init)
                if parts.count == 2, secondTokenStoplist.contains(parts[1]) { parts.removeLast() }
                name = parts.joined(separator: " ")
                found = name
            }
            if let name = found, !name.isEmpty,
               name.lowercased() != myName.lowercased(),
               !["Everyone", "Here", "Going", "Sure", "Just", "Also", "Thanks"].contains(name) {
                out[t.speaker] = Candidate(name: name, confidence: 0.8, evidence: "self-introduction: \"\(head.prefix(80))\" [\(Timestamps.clock(t.start))]")
            }
        }
        return out
    }
}
