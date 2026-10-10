import Foundation

struct ChatGPTModelChoice: Identifiable, Decodable {
    var id: String { slug }
    let slug: String
    let display_name: String
    let visibility: String
}

/// Follow the subscription route's narrower Responses API contract. No model ID
/// is guessed: the account's live catalog supplies it.
struct ChatGPTRequestConfiguration {
    let model: String
    let webSearch: Bool
    let system: String

    func payload(input: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "instructions": system, "input": input,
            "store": false, "stream": true
        ]
        if webSearch { body["tools"] = [["type": "web_search"]] }
        return body
    }

    /// Convert Byte's locally saved conversation, preserving images and omitting
    /// interrupted assistant replies. The final turn is the pending placeholder.
    static func input(turns: [ByteModel.Turn]) -> [[String: Any]] {
        turns.dropLast().compactMap { turn in
            if turn.role == .byte, turn.failure != nil { return nil }
            var content: [[String: Any]] = []
            if !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content.append(["type": turn.role == .user ? "input_text" : "output_text", "text": turn.text])
            }
            if turn.role == .user, let image = turn.imageB64 {
                content.append(["type": "input_image", "image_url": "data:\(turn.imageType ?? "image/jpeg");base64,\(image)"])
            }
            guard !content.isEmpty else { return nil }
            return ["role": turn.role == .user ? "user" : "assistant", "content": content]
        }
    }
}

struct ChatGPTStreamEvent {
    let type: String
    let object: [String: Any]

    init?(line: String) {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        self.type = type; self.object = object
    }

    var text: String? {
        if type == "response.output_text.delta" { return object["delta"] as? String }
        if type == "response.refusal.delta" { return object["delta"] as? String }
        return nil
    }

    var failure: String? {
        switch type {
        case "response.failed":
            let response = object["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            return Self.errorMessage(error)
        case "response.incomplete":
            return "The reply couldn't finish. Ask Byte to continue."
        case "error":
            return Self.errorMessage(object)
        default: return nil
        }
    }

    static func errorMessage(_ error: [String: Any]?) -> String {
        switch error?["code"] as? String {
        case "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable":
            return "ChatGPT plan usage is unavailable or its limit was reached. Review your plan and Byte's limit in Manage usage."
        case "subscription_sharing_not_enabled", "insufficient_scope":
            return "ChatGPT plan usage isn't enabled for Byte. Continue with ChatGPT again and enable plan usage."
        default:
            return (error?["message"] as? String) ?? "ChatGPT couldn't complete this request. Try again."
        }
    }
}
