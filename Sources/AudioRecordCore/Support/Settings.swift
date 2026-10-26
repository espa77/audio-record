import Foundation

public enum ASREngineKind: String, CaseIterable, Codable {
    case parakeetUltra   // FluidAudio, Parakeet Ultra (multilingual, Core ML)
    case appleSpeech     // Apple SpeechAnalyzer (macOS 26+), no model download

    public var label: String {
        switch self {
        case .parakeetUltra: return "Parakeet Ultra (FluidAudio)"
        case .appleSpeech: return "Apple Speech (built-in)"
        }
    }
}

/// Persisted in the shared suite so the app and the CLI see the same values.
public struct Settings: Codable, Equatable {
    public static let suiteName = "com.esteiner.audiorecord"

    public var outputRoot: URL
    public var myName: String
    public var asrEngine: ASREngineKind
    public var llmEndpoint: URL
    public var llmModel: String          // empty = first model LM Studio reports
    public var llmEnabled: Bool
    public var keepLosslessTracks: Bool
    public var vocabularyEnabled: Bool   // bias ASR towards Resources/vocabulary.txt

    public static var defaults: Settings {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let full = NSFullUserName()
        let first = full.split(separator: " ").first.map(String.init) ?? ""
        return Settings(
            outputRoot: home.appendingPathComponent("Recordings/Meetings", isDirectory: true),
            myName: first.isEmpty ? "Me" : first.capitalized,
            asrEngine: .parakeetUltra,
            llmEndpoint: URL(string: "http://localhost:1234/v1/chat/completions")!,
            llmModel: "",
            llmEnabled: true,
            keepLosslessTracks: false,
            vocabularyEnabled: true
        )
    }

    public static func load() -> Settings {
        guard let ud = UserDefaults(suiteName: suiteName),
              let data = ud.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .defaults
        }
        return s
    }

    public func save() {
        guard let ud = UserDefaults(suiteName: Settings.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        ud.set(data, forKey: "settings")
    }

    public var inProgressDir: URL { outputRoot.appendingPathComponent(".inprogress", isDirectory: true) }
}

extension Settings {
    enum CodingKeys: String, CodingKey {
        case outputRoot, myName, asrEngine, llmEndpoint, llmModel, llmEnabled, keepLosslessTracks, vocabularyEnabled
    }

    /// Keys added after the first release decode with a default, so saved settings survive upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputRoot = try c.decode(URL.self, forKey: .outputRoot)
        myName = try c.decode(String.self, forKey: .myName)
        asrEngine = try c.decode(ASREngineKind.self, forKey: .asrEngine)
        llmEndpoint = try c.decode(URL.self, forKey: .llmEndpoint)
        llmModel = try c.decode(String.self, forKey: .llmModel)
        llmEnabled = try c.decode(Bool.self, forKey: .llmEnabled)
        keepLosslessTracks = try c.decode(Bool.self, forKey: .keepLosslessTracks)
        vocabularyEnabled = try c.decodeIfPresent(Bool.self, forKey: .vocabularyEnabled) ?? true
    }
}
