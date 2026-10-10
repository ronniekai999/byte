import Foundation
import CryptoKit
import Security
import XCTest
@testable import Byte

private final class ChatGPTMemoryStore: APIKeyStoring {
    var key: String?
    var failSave = false
    func read() throws -> String? { key }
    func save(_ key: String) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        self.key = key
    }
    func remove() throws { key = nil }
}

final class ChatGPTTests: XCTestCase {
    private let callbackURL = URL(string: "http://127.0.0.1:54321/auth/callback")!

    private func attempt(account: ChatGPTAccount? = nil) throws -> ChatGPTOAuthAttempt {
        try ChatGPTOAuthAttempt(redirectURI: callbackURL, hostID: "urn:uuid:test-host", account: account)
    }

    private func callback(_ attempt: ChatGPTOAuthAttempt, fields: [URLQueryItem] = []) -> URL {
        var url = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "code", value: "fake-code")] + fields
        return url.url!
    }

    func testDynamicRegistrationAndFreshPKCE() throws {
        let first = try attempt(), second = try attempt()
        let url = first.authorizationURL(endpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!)
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["client_id"], "dynamic_agent_client")
        XCTAssertEqual(values["agent_name_hint"], "Byte")
        XCTAssertEqual(values["resource"], "https://api.openai.com/v1")
        XCTAssertTrue(values["scope"]!.contains("chatgpt.tokens.use.direct"))
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(first.challenge, Data(SHA256.hash(data: Data(first.verifier.utf8))).base64URL)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.verifier, second.verifier)
    }

    func testCallbackRequiresIssuedClientAndMatchingTransaction() throws {
        let pending = try attempt()
        XCTAssertThrowsError(try pending.callback(callback(pending)))
        XCTAssertThrowsError(try pending.callback(callback(pending, fields: [.init(name: "client_id", value: "dynamic_agent_client")])))
        let valid = callback(pending, fields: [.init(name: "client_id", value: "oaiapp_byte")])
        XCTAssertEqual(try pending.callback(valid).clientID, "oaiapp_byte")
        XCTAssertThrowsError(try pending.callback(valid, now: pending.expiresAt))
        XCTAssertThrowsError(try attempt().callback(valid))
        XCTAssertThrowsError(try pending.callback(URL(string: valid.absoluteString.replacingOccurrences(of: "/auth/callback", with: "/callback"))!))
        XCTAssertThrowsError(try pending.callback(callback(pending, fields: [.init(name: "state", value: pending.state)])))
    }

    func testReturningRegistrationCannotBeReplacedByAnotherClient() throws {
        let account = ChatGPTAccount(clientID: "oaiapp_saved", subject: "subject", email: "user@example.com", tokens: nil)
        let pending = try attempt(account: account)
        XCTAssertEqual(try pending.callback(callback(pending)).clientID, account.clientID)
        XCTAssertThrowsError(try pending.callback(callback(pending, fields: [.init(name: "client_id", value: "oaiapp_other")])))
        let url = pending.authorizationURL(endpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!)
        XCTAssertFalse(url.absoluteString.contains("agent_name_hint"))
        XCTAssertTrue(url.absoluteString.contains("prompt=consent"))
        let recovering = try ChatGPTOAuthAttempt(redirectURI: callbackURL, hostID: "urn:uuid:test-host",
                                                account: nil, registeredClientID: "oaiapp_issued")
        XCTAssertEqual(try recovering.callback(callback(recovering)).clientID, "oaiapp_issued")
        XCTAssertThrowsError(try recovering.callback(callback(recovering, fields: [.init(name: "client_id", value: "oaiapp_other")])))
    }

    func testIDTokenVerificationRejectsTamperingAndWrongClaims() throws {
        let key = P256.Signing.PrivateKey()
        let publicBytes = key.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "test", "alg": "ES256", "kty": "EC", "crv": "P-256", "use": "sig",
            "x": Data(publicBytes[1..<33]).base64URL, "y": Data(publicBytes[33..<65]).base64URL
        ]]])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_byte", "sub": "subject",
            "nonce": "nonce", "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(60).timeIntervalSince1970]
        func signed(_ claims: [String: Any]) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "test"]).base64URL
            let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
            let message = "\(header).\(payload)"
            return try message + "." + key.signature(for: Data(message.utf8)).rawRepresentation.base64URL
        }
        func verify(_ token: String) throws -> ChatGPTIdentity {
            try ChatGPTIdentity.verify(token, jwks: jwks, algorithms: ["ES256"], clientID: "oaiapp_byte", nonce: "nonce", now: now)
        }
        let token = try signed(claims)
        XCTAssertEqual(try verify(token).subject, "subject")
        let parts = token.split(separator: ".")
        XCTAssertThrowsError(try verify("\(parts[0]).\(parts[1]).\(Data(repeating: 0, count: 64).base64URL)"))
        for (field, value) in [("iss", "https://other.example"), ("aud", "oaiapp_other"), ("nonce", "other")] {
            var wrong = claims; wrong[field] = value
            XCTAssertThrowsError(try verify(signed(wrong)))
        }
        var expired = claims; expired["exp"] = now.timeIntervalSince1970 - 1
        XCTAssertThrowsError(try verify(signed(expired)))
        XCTAssertThrowsError(try ChatGPTIdentity.verify(token, jwks: jwks, algorithms: ["RS256"], clientID: "oaiapp_byte", nonce: "nonce", now: now))
    }

    func testRS256IdentityTokenVerifiesWithPublishedRSAKey() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var index = 0
        func read(_ tag: UInt8) throws -> Data {
            XCTAssertEqual(der[index], tag); index += 1
            let first = der[index]; index += 1
            var count = Int(first)
            if first & 0x80 != 0 {
                count = 0
                for _ in 0..<Int(first & 0x7f) { count = (count << 8) | Int(der[index]); index += 1 }
            }
            if tag == 0x30 { return Data() }
            defer { index += count }
            return Data(der[index..<(index + count)].drop(while: { $0 == 0 }))
        }
        _ = try read(0x30)
        let n = try read(0x02), e = try read(0x02)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "rsa-test", "kty": "RSA", "alg": "RS256", "n": n.base64URL, "e": e.base64URL
        ]]])
        let now = Date()
        let header = try JSONSerialization.data(withJSONObject: ["kid": "rsa-test", "alg": "RS256"]).base64URL
        let payload = try JSONSerialization.data(withJSONObject: ["iss": "https://auth.openai.com", "aud": "oaiapp_byte",
            "sub": "rsa-user", "nonce": "nonce", "iat": now.timeIntervalSince1970,
            "exp": now.addingTimeInterval(60).timeIntervalSince1970]).base64URL
        let signed = "\(header).\(payload)"
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)) as Data
        let identity = try ChatGPTIdentity.verify("\(signed).\(signature.base64URL)", jwks: jwks,
            algorithms: ["RS256"], clientID: "oaiapp_byte", nonce: "nonce", now: now)
        XCTAssertEqual(identity.subject, "rsa-user")
    }

    @MainActor
    func testLoopbackListenerIgnoresWrongStateAndAcceptsOneCallback() async throws {
        let listener = OAuthLoopbackListener()
        defer { listener.cancel() }
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        listener.expectedState = "expected"
        let wrong = URL(string: redirect.absoluteString + "?state=wrong&code=fake")!
        let (_, response) = try await URLSession.shared.data(from: wrong)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let valid = URL(string: redirect.absoluteString + "?state=expected&code=fake&client_id=oaiapp_byte")!
        async let callback = listener.waitForCallback()
        let (_, accepted) = try await URLSession.shared.data(from: valid)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let returned = try await callback
        XCTAssertEqual(returned, valid)
    }

    @MainActor
    func testHostIDPersistsAcrossSignInsAndAccountRecordsStaySeparate() throws {
        let suite = "ChatGPTTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatGPTMemoryStore()
        let accounts = ["oaiapp_first", "oaiapp_second"].map {
            ChatGPTAccount(clientID: $0, subject: "same-user", email: "user@example.com", tokens: nil)
        }
        store.key = String(decoding: try JSONEncoder().encode(accounts), as: UTF8.self)
        let auth = ChatGPTAuth(store: store, defaults: defaults)
        let host = auth.hostID
        auth.selectAccount(accounts[1].clientID)
        let reloaded = ChatGPTAuth(store: store, defaults: defaults)
        XCTAssertEqual(reloaded.hostID, host)
        XCTAssertEqual(reloaded.activeAccount?.clientID, accounts[1].clientID)
        XCTAssertNotEqual(accounts[0].label, accounts[1].label)
        XCTAssertFalse(reloaded.canUsePlan)
    }

    func testSubscriptionRequestOmitsUnsupportedFieldsAndFailedHistory() throws {
        var failed = ByteModel.Turn(role: .byte, text: "Partial answer")
        failed.failure = "Stopped"
        let turns: [ByteModel.Turn] = [.init(role: .user, text: "Question", imageType: "image/jpeg", imageB64: "aW1hZ2U="),
            failed, .init(role: .user, text: "Try again"), .init(role: .byte, text: "")]
        let input = ChatGPTRequestConfiguration.input(turns: turns)
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual((input[0]["content"] as? [[String: Any]])?.last?["image_url"] as? String, "data:image/jpeg;base64,aW1hZ2U=")
        let body = ChatGPTRequestConfiguration(model: "server-model", webSearch: false, system: "Byte")
            .payload(input: input)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "Byte")
        for field in ["max_output_tokens", "max_tool_calls", "previous_response_id", "temperature", "tools"] { XCTAssertNil(body[field]) }
    }

    func testUsageLimitAfterStreamingIsAFailure() {
        let event = ChatGPTStreamEvent(line: #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)
        XCTAssertTrue(event?.failure?.contains("Manage usage") == true)
        XCTAssertNotNil(ChatGPTStreamEvent(line: #"data: {"type":"response.incomplete"}"#)?.failure)
    }

    func testFormEncodingProtectsTokenCharacters() {
        let body = String(decoding: ChatGPTAuth.formData(["refresh_token": "token+&= value"]), as: UTF8.self)
        XCTAssertEqual(body, "refresh_token=token%2B%26%3D%20value")
    }
}
