import Foundation

/// Snapshot these settings once per send so retries and billing use the same model.
struct AnthropicRequestConfiguration {
    let model: String
    let effort: String
    let webSearch: Bool
    let system: String

    static let visionModels: Set<String> = [
        "claude-sonnet-4-6", "claude-opus-4-8", "claude-haiku-4-5-20251001"
    ]

    static func supportsAdaptiveThinking(_ model: String) -> Bool {
        ["claude-sonnet-4-6", "claude-opus-4-8"].contains(model)
    }

    func payload(messages: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "max_tokens": 8192, "stream": true,
            "system": system, "messages": messages
        ]
        if Self.supportsAdaptiveThinking(model) {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        }
        if webSearch {
            body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]]
        }
        return body
    }
}

struct AnthropicUsage {
    var inputTokens = 0
    var outputTokens = 0
    var searches = 0

    /// Streaming usage fields are cumulative. The final input count can grow after a search.
    mutating func update(from usage: [String: Any]) {
        if let value = usage["input_tokens"] as? Int { inputTokens = value }
        if let value = usage["output_tokens"] as? Int { outputTokens = value }
        if let tool = usage["server_tool_use"] as? [String: Any],
           let value = tool["web_search_requests"] as? Int { searches = value }
    }
}
