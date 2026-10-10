import AppKit
import XCTest
@testable import Byte

private final class MemoryKeyStore: APIKeyStoring {
    var key: String?
    var failSave = false
    var failRemove = false
    init(key: String? = "test-key") { self.key = key }
    func read() throws -> String? { key }
    func save(_ key: String) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        self.key = key
    }
    func remove() throws {
        if failRemove { throw CocoaError(.fileWriteNoPermission) }
        key = nil
    }
}

private final class StubURLProtocol: URLProtocol {
    // XCTest runs these cases serially; no real API calls or credentials are used.
    static var handler: ((StubURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func reply(_ body: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    func requestBody() -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let keys: MemoryKeyStore
    let session: URLSession
    let model: ByteModel

    init(key: String? = "test-key") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "ByteTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        keys = MemoryKeyStore(key: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        model = ByteModel(configDirectory: root, defaults: defaults, keyStore: keys,
                          session: session, environment: [:],
                          now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    func cleanup() {
        model.prepareForTermination()
        session.invalidateAndCancel()
        StubURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func reloaded() -> ByteModel {
        ByteModel(configDirectory: root, defaults: defaults, keyStore: keys,
                  session: session, environment: [:])
    }
}

final class ByteModelTests: XCTestCase {
    @MainActor
    private func waitForFinish(_ model: ByteModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isStreaming && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isStreaming, "The response should settle within five seconds.")
    }

    @MainActor
    func testTwoArchivesInTheSameSecondBothSurvive() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.model.turns = [.init(role: .user, text: "First")]
        f.model.newChat()
        f.model.turns = [.init(role: .user, text: "Second")]
        f.model.newChat()
        let archives = f.model.archiveList()
        XCTAssertEqual(archives.count, 2)
        XCTAssertEqual(Set(archives.map(\.preview)), Set(["First", "Second"]))
        XCTAssertEqual(Set(archives.map(\.id)).count, 2)
        XCTAssertFalse(archives.first!.dateString.contains("20231114-"))
    }

    @MainActor
    func testArchiveWriteFailureKeepsCurrentChat() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try Data("blocked".utf8).write(to: f.root.appendingPathComponent("archives"))
        f.model.turns = [.init(role: .user, text: "Keep this")]
        f.model.newChat()
        XCTAssertEqual(f.model.turns.first?.text, "Keep this")
        XCTAssertNotNil(f.model.storageError)
        XCTAssertFalse(f.model.hasArchive)
    }

    @MainActor
    func testReopenKeepsArchiveWhenSavingHistoryFails() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.model.turns = [.init(role: .user, text: "Archived")]
        f.model.newChat()
        let archive = try XCTUnwrap(f.model.archiveList().first)
        let history = f.root.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        XCTAssertFalse(f.model.reopenArchive(id: archive.id))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("archives/\(archive.id)").path))
        XCTAssertTrue(f.model.turns.isEmpty)
        XCTAssertNotNil(f.model.storageError)
    }

    @MainActor
    func testFailedImageWriteDoesNotStampASidecarID() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try Data("blocked".utf8).write(to: f.root.appendingPathComponent("images"))
        f.model.turns = [.init(role: .user, text: "", imageType: "image/jpeg",
                              imageB64: Data("image".utf8).base64EncodedString())]
        f.model.newChat()
        XCTAssertEqual(f.model.turns.count, 1)
        XCTAssertNil(f.model.turns.first?.imageId)
        XCTAssertNotNil(f.model.storageError)
    }

    @MainActor
    func testNewChatClearsDraftAndPendingAttachment() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.model.draft = "Old draft"
        f.model.pendingImageB64 = "aW1hZ2U="
        f.model.pendingImageType = "image/jpeg"
        f.model.newChat()
        XCTAssertTrue(f.model.draft.isEmpty)
        XCTAssertNil(f.model.pendingImageB64)
    }

    @MainActor
    func testLegacyKeyMovesIntoKeychainBeforeFileRemoval() throws {
        let f = try Fixture(key: nil)
        defer { f.cleanup() }
        let path = f.root.appendingPathComponent("api_key")
        try " legacy-key \n".write(to: path, atomically: true, encoding: .utf8)
        let reloaded = f.reloaded()
        XCTAssertTrue(reloaded.hasKey)
        XCTAssertEqual(f.keys.key, "legacy-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    @MainActor
    func testFailedKeyMigrationPreservesTheLegacyFile() throws {
        let f = try Fixture(key: nil)
        defer { f.cleanup() }
        f.keys.failSave = true
        let path = f.root.appendingPathComponent("api_key")
        try "legacy-key".write(to: path, atomically: true, encoding: .utf8)
        let reloaded = f.reloaded()
        XCTAssertTrue(reloaded.hasKey)
        XCTAssertNil(f.keys.key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNotNil(reloaded.storageError)
    }

    @MainActor
    func testFailedKeySaveDoesNotClaimConnectionOrClearInput() throws {
        let f = try Fixture(key: nil)
        defer { f.cleanup() }
        f.keys.failSave = true
        f.model.keyInput = "new-key"
        f.model.saveKey()
        XCTAssertFalse(f.model.hasKey)
        XCTAssertEqual(f.model.keyInput, "new-key")
        XCTAssertNotNil(f.model.storageError)
    }

    @MainActor
    func testSignOutFailureKeepsConnectionStateTruthful() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.keys.failRemove = true
        f.model.signOut()
        XCTAssertTrue(f.model.hasKey)
        XCTAssertNotNil(f.model.storageError)
    }

    @MainActor
    func testHaikuImageAttachmentKeepsHaikuSelected() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.defaults.set("claude-haiku-4-5-20251001", forKey: "byte.model")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.addRepresentation(bitmap)
        f.model.attachImage(image)
        XCTAssertNotNil(f.model.pendingImageB64)
        XCTAssertEqual(f.model.model, "claude-haiku-4-5-20251001")
    }

    @MainActor
    func testLocalErrorsAndEmptyRepliesAreExcludedFromAPIHistory() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var failed = ByteModel.Turn(role: .byte, text: "Partial answer")
        failed.failure = "Network error"
        f.model.turns = [.init(role: .user, text: "First"), failed,
                         .init(role: .byte, text: ""), .init(role: .user, text: "Next"),
                         .init(role: .byte, text: "")]
        let messages = f.model.apiMessages()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "user"])
    }

    @MainActor
    func testArchivePathsCannotEscapeTheArchiveDirectory() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let file = f.root.appendingPathComponent("chat-outside.json")
        try Data("keep".utf8).write(to: file)
        f.model.deleteArchive(id: "../chat-outside.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(f.model.reopenArchive(id: "../chat-outside.json"))
    }

    @MainActor
    func testCompletedStreamUsesSendTimeSettingsAndFinalUsage() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        StubURLProtocol.handler = { stub in
            if let data = stub.requestBody(),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-6")
            } else {
                XCTFail("The request must carry a JSON payload.")
            }
            stub.reply("""
            data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":25,"output_tokens":5,"server_tool_use":{"web_search_requests":2}}}

            data: {"type":"message_stop"}


            """)
        }
        f.model.draft = "Hello"
        f.model.send()
        f.defaults.set("claude-haiku-4-5-20251001", forKey: "byte.model")
        try await waitForFinish(f.model)
        XCTAssertEqual(f.model.turns.last?.text, "Hello")
        XCTAssertNil(f.model.turns.last?.failure)
        XCTAssertEqual(f.model.sessionInTok, 25)
        XCTAssertEqual(f.model.sessionOutTok, 5)
        XCTAssertEqual(f.model.sessionSearches, 2)
        XCTAssertEqual(f.model.sessionCost, 0.02015, accuracy: 0.0000001)
    }

    @MainActor
    func testEOFWithoutMessageStopIsAnIncompleteReply() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        StubURLProtocol.handler = { stub in
            stub.reply("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Partial"}}


            """)
        }
        f.model.draft = "Question"
        f.model.send()
        try await waitForFinish(f.model)
        XCTAssertEqual(f.model.turns.last?.text, "Partial")
        XCTAssertTrue(f.model.turns.last?.failure?.contains("before the reply finished") == true)
    }

    @MainActor
    func testPromptAndImageAreSavedBeforeNetworkingStarts() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.model.draft = "Persist me"
        f.model.pendingImageB64 = Data("image".utf8).base64EncodedString()
        f.model.pendingImageType = "image/jpeg"
        f.model.send()
        let data = try Data(contentsOf: f.root.appendingPathComponent("history.json"))
        let turns = try JSONDecoder().decode([ByteModel.Turn].self, from: data)
        XCTAssertEqual(turns.first?.text, "Persist me")
        let imageID = try XCTUnwrap(turns.first?.imageId)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("images/\(imageID).jpg").path))
        XCTAssertNotNil(turns.last?.failure)
    }

    @MainActor
    func testStoppingThenSendingAgainCannotCorruptTheNewReply() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let started = expectation(description: "First request is waiting")
        StubURLProtocol.handler = { _ in started.fulfill() }
        f.model.draft = "First question"
        f.model.send()
        await fulfillment(of: [started], timeout: 2)
        f.model.stopResponse()
        XCTAssertFalse(f.model.isStreaming)
        StubURLProtocol.handler = { stub in
            stub.reply("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"New reply"}}

            data: {"type":"message_stop"}


            """)
        }
        f.model.draft = "Second question"
        f.model.send()
        try await waitForFinish(f.model)
        XCTAssertEqual(f.model.turns[1].failure, "Reply stopped.")
        XCTAssertEqual(f.model.turns.last?.text, "New reply")
        XCTAssertNil(f.model.turns.last?.failure)
        XCTAssertFalse(f.model.isThinking)
    }

    @MainActor
    func testHTTP401FailsWithoutRetryingOrInventingAnAssistantAnswer() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let request = expectation(description: "One request")
        request.assertForOverFulfill = true
        StubURLProtocol.handler = { stub in
            request.fulfill()
            stub.reply(#"{"error":{"message":"Invalid API key"}}"#, status: 401)
        }
        f.model.draft = "Question"
        f.model.send()
        try await waitForFinish(f.model)
        await fulfillment(of: [request], timeout: 2)
        XCTAssertEqual(f.model.turns.last?.text, "")
        XCTAssertTrue(f.model.turns.last?.failure?.contains("Invalid API key") == true)
    }

    @MainActor
    func testUnreadableHistoryIsBackedUpBeforeItCanBeOverwritten() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let original = Data("invalid JSON".utf8)
        try original.write(to: f.root.appendingPathComponent("history.json"))
        let model = f.reloaded()
        XCTAssertNotNil(model.storageError)
        model.newChat()
        let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history-recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
        let current = try Data(contentsOf: f.root.appendingPathComponent("history.json"))
        XCTAssertTrue(try JSONDecoder().decode([ByteModel.Turn].self, from: current).isEmpty)
    }

    @MainActor
    func testStoppingDuringRateLimitBackoffPreventsAnotherAttempt() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let request = expectation(description: "Only the first attempt runs")
        request.assertForOverFulfill = true
        StubURLProtocol.handler = { stub in
            request.fulfill()
            stub.reply(#"{"error":{"message":"Rate limited"}}"#, status: 429)
        }
        f.model.draft = "Question"
        f.model.send()
        await fulfillment(of: [request], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        f.model.stopResponse()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(f.model.isStreaming)
        XCTAssertEqual(f.model.turns.last?.failure, "Reply stopped.")
    }

    @MainActor
    func testStreamOnlyKeepsDistinctWebCitations() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        StubURLProtocol.handler = { stub in
            stub.reply("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Answer"}}

            data: {"type":"content_block_delta","delta":{"type":"citations_delta","citation":{"title":"Unsafe","url":"file:///tmp/private.txt"}}}

            data: {"type":"content_block_delta","delta":{"type":"citations_delta","citation":{"title":"Source","url":"https://example.com/source"}}}

            data: {"type":"content_block_delta","delta":{"type":"citations_delta","citation":{"title":"Duplicate","url":"https://example.com/source"}}}

            data: {"type":"message_stop"}


            """)
        }
        f.model.draft = "Question"
        f.model.send()
        try await waitForFinish(f.model)
        XCTAssertEqual(f.model.turns.last?.sources.count, 1)
        XCTAssertEqual(f.model.turns.last?.sources.first?.url, "https://example.com/source")
    }
}
