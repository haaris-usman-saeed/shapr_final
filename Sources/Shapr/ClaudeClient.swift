import Foundation
import Security

/// Minimal raw-HTTP client for the Claude Messages API (there is no official Swift SDK).
/// Used only when the user turns on the Claude engine and pastes an API key.
struct ClaudeClient {
    let apiKey: String
    let model: String

    enum ClientError: LocalizedError {
        case http(Int, String)
        case refusal
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "Claude API error \(code): \(msg)"
            case .refusal: return "Claude declined this request."
            case .badResponse(let s): return "Unexpected response: \(s)"
            }
        }
    }

    static let choiceSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "pack": ["type": "string", "description": "Exact name of the existing pack, or NEW"],
            "topic_name": ["type": "string", "description": "1-3 word name for the broad subject of this snippet, as if it were a new pack"],
            "emoji": ["type": "string", "description": "One emoji for the topic"],
        ],
        "required": ["pack", "topic_name", "emoji"],
        "additionalProperties": false,
    ]

    static let nameSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Short 1-3 word pack name"],
            "emoji": ["type": "string", "description": "One emoji for the topic"],
        ],
        "required": ["name", "emoji"],
        "additionalProperties": false,
    ]

    /// Server-side refusal fallback is supported on Opus / Sonnet 5.5 (not Haiku).
    private var supportsFallbacks: Bool { model.contains("opus") || model.contains("sonnet") || model.contains("fable") }

    /// Sends one request with a JSON-schema output format and returns the parsed object.
    func structured(system: String, prompt: String, schema: [String: Any], effort: String = "low",
                    maxTokens: Int = 4000) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            // Sorting is a quick classification, so it runs at low effort; form answers use medium.
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
        ]
        if supportsFallbacks { body["fallbacks"] = "default" }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if supportsFallbacks { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard status == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "request failed"
            throw ClientError.http(status, msg)
        }
        if json["stop_reason"] as? String == "refusal" { throw ClientError.refusal }

        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let out = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ClientError.badResponse("no JSON text block")
        }
        return out
    }
}

/// Stores the API key in the login Keychain, never in plain files or defaults.
enum Keychain {
    static let defaultService = "app.shapr.Shapr"
    /// Test and snapshot runs never read or write the real app's items, so macOS never shows a
    /// Keychain password prompt for them.
    static var blockedServices: Set<String> = []

    static func get(_ account: String, service: String = defaultService) -> String? {
        if blockedServices.contains(service) { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.nonEmpty
    }

    static func set(_ value: String?, account: String, service: String = defaultService) {
        if blockedServices.contains(service) { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value = value?.nonEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Streaming (used by Drop)

extension ClaudeClient {
    /// Streams the text of one reply. Thinking blocks and other events are skipped.
    /// `images`: PNG screenshots to send with the prompt (Claude reads them).
    func stream(system: String, prompt: String, images: [Data] = [], effort: String = "medium",
                maxTokens: Int = 8000) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "stream": true,
                        "system": system,
                        "messages": [["role": "user", "content": images.isEmpty ? prompt as Any : (images.map { png -> [String: Any] in
                            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
                        } + [["type": "text", "text": prompt]]) as Any]],
                        "output_config": ["effort": effort],
                    ]
                    if supportsFallbacks { body["fallbacks"] = "default" }

                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
                    if supportsFallbacks { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var raw = Data()
                        for try await b in bytes { raw.append(b); if raw.count > 4000 { break } }
                        let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
                        let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "request failed"
                        throw ClientError.http(status, msg)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        switch obj["type"] as? String {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if (obj["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                                throw ClientError.refusal
                            }
                        case "error":
                            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
                            throw ClientError.http(0, msg)
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
