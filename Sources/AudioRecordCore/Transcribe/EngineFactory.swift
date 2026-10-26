import Foundation

public enum Engines {
    public static func make(_ kind: ASREngineKind, vocabulary: Vocabulary = .empty) throws -> ASREngine {
        switch kind {
        case .parakeetUltra:
            return ParakeetASR(version: .ultra, vocabulary: vocabulary)
        case .appleSpeech:
            if #available(macOS 26, *) { return AppleSpeechASR(vocabulary: vocabulary) }
            throw AudioRecordError("Apple Speech needs macOS 26 or later")
        }
    }

    /// The bundled vocabulary when enabled in settings; empty otherwise.
    public static func vocabulary(for settings: Settings) -> Vocabulary {
        settings.vocabularyEnabled ? Vocabulary.bundled() : .empty
    }

    /// Builds the LLM client when enabled and the local server answers; nil otherwise.
    public static func llmClient(for settings: Settings) async -> LLMClient? {
        guard settings.llmEnabled else { return nil }
        let client = OpenAICompatibleClient(endpoint: settings.llmEndpoint, model: settings.llmModel)
        return await client.isReachable() ? client : nil
    }
}
