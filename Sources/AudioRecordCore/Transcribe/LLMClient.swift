import Foundation

public protocol LLMClient: AnyObject {
    var describe: String { get }
    /// Returns the assistant message content. Implementations should request JSON output.
    func complete(system: String, user: String) async throws -> String
}

struct LLMHTTPError: Error {
    let status: Int
    let body: String
}

/// OpenAI-compatible chat completions (LM Studio, llama-server, Ollama's /v1) on localhost.
public final class OpenAICompatibleClient: LLMClient {
    public let endpoint: URL
    public private(set) var model: String
    private let session: URLSession

    public init(endpoint: URL, model: String = "") {
        self.endpoint = endpoint
        self.model = model
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 900
        session = URLSession(configuration: cfg)
    }

    public var describe: String { "\(model.isEmpty ? "auto" : model) @ \(endpoint.host ?? "?"):\(endpoint.port ?? 80)" }

    /// True when the server answers /v1/models. Resolves the model id when none was configured.
    public func isReachable() async -> Bool {
        guard let base = modelsURL else { return false }
        var req = URLRequest(url: base)
        req.timeoutInterval = 5
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        if model.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [[String: Any]] {
            let ids = list.compactMap { $0["id"] as? String }
            if let first = ids.first(where: { !$0.lowercased().contains("embed") }) ?? ids.first { model = first }
        }
        return true
    }

    private var modelsURL: URL? {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        c?.path = "/v1/models"
        c?.query = nil
        return c?.url
    }

    /// LM Studio accepts only `json_schema` or `text`; other servers may accept neither, so fall back to plain text.
    static let jsonSchemaFormat: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "speaker_names",
            "schema": [
                "type": "object",
                "additionalProperties": [
                    "type": "object",
                    "properties": [
                        "name": ["type": ["string", "null"]],
                        "confidence": ["type": "number"],
                        "evidence": ["type": "string"],
                    ],
                    "required": ["name", "confidence", "evidence"],
                ],
            ],
        ],
    ]

    public func complete(system: String, user: String) async throws -> String {
        if model.isEmpty { _ = await isReachable() }
        do {
            return try await send(system: system, user: user, responseFormat: Self.jsonSchemaFormat)
        } catch let error as LLMHTTPError where error.status == 400 {
            return try await send(system: system, user: user, responseFormat: nil)
        }
    }

    private func send(system: String, user: String, responseFormat: [String: Any]?) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 1200,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let responseFormat { body["response_format"] = responseFormat }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw LLMHTTPError(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AudioRecordError("LLM response had no content")
        }
        return content
    }
}
