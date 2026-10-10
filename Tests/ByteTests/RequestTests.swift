import XCTest
@testable import Byte

final class RequestTests: XCTestCase {
    func testHaikuOmitsUnsupportedAdaptiveThinkingAndEffort() {
        let configuration = AnthropicRequestConfiguration(
            model: "claude-haiku-4-5-20251001", effort: "high",
            webSearch: false, system: "Test")
        let body = configuration.payload(messages: [["role": "user", "content": "Hello"]])
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["model"] as? String, configuration.model)
    }

    func testSonnetAndOpusKeepAdaptiveThinkingAndSearchCap() {
        for model in ["claude-sonnet-4-6", "claude-opus-4-8"] {
            let body = AnthropicRequestConfiguration(
                model: model, effort: "medium", webSearch: true, system: "Test")
                .payload(messages: [])
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "adaptive")
            XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "medium")
            XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["max_uses"] as? Int, 5)
        }
    }

    func testHaiku45IsVisionCapable() {
        XCTAssertTrue(AnthropicRequestConfiguration.visionModels.contains("claude-haiku-4-5-20251001"))
    }

    func testUsageUsesFinalCumulativeCountsWithoutDoubleCounting() {
        var usage = AnthropicUsage()
        usage.update(from: ["input_tokens": 12, "output_tokens": 1])
        usage.update(from: ["input_tokens": 40, "output_tokens": 8,
                            "server_tool_use": ["web_search_requests": 2]])
        usage.update(from: ["output_tokens": 10])
        XCTAssertEqual(usage.inputTokens, 40)
        XCTAssertEqual(usage.outputTokens, 10)
        XCTAssertEqual(usage.searches, 2)
    }

    func testLegacyHistoryDecodesWithoutNewFailureField() throws {
        let data = Data(#"[{"role":"finn","text":"Hello","sources":[]}]"#.utf8)
        let turns = try JSONDecoder().decode([ByteModel.Turn].self, from: data)
        XCTAssertEqual(turns.first?.role, .byte)
        XCTAssertNil(turns.first?.failure)
    }

    func testGeneratedLinksOnlyOpenWebURLsWithAHost() {
        for raw in ["https://example.com/source", "http://example.com"] {
            XCTAssertTrue(WebLinks.canOpen(URL(string: raw)!))
        }
        for raw in ["file:///tmp/private.txt", "mailto:person@example.com", "x-apple.systempreferences:settings", "/relative"] {
            XCTAssertFalse(WebLinks.canOpen(URL(string: raw)!))
        }
    }
}
