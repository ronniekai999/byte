import Foundation
import Combine
import CryptoKit
import Security

struct ChatGPTAccount: Codable, Identifiable {
    var id: String { clientID }
    let clientID: String
    let subject: String
    let email: String?
    var tokens: ChatGPTTokens?

    // Registrations for different workspaces may have the same email.
    var label: String { "\(email ?? "ChatGPT account") · \(clientID.suffix(8))" }
}

struct ChatGPTTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date
    let scopes: [String]
    var canUsePlan: Bool {
        scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") &&
        !accessToken.isEmpty && !refreshToken.isEmpty
    }
}

struct ChatGPTConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private struct ChatGPTAuthorizationHTTPError: LocalizedError {
    let status: Int
    let code: String?
    var errorDescription: String? { "ChatGPT sign-in needs to be retried (HTTP \(status)). Continue with ChatGPT again." }
    var endsSession: Bool {
        ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
         "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "")
    }
}

/// A single, short-lived public-client OAuth transaction. No client secret or
/// Codex credentials are used. The callback's issued client ID belongs to Byte.
struct ChatGPTOAuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: URL
    let hostID: String
    let account: ChatGPTAccount?
    let clientID: String?
    let expiresAt: Date

    init(redirectURI: URL, hostID: String, account: ChatGPTAccount?,
         registeredClientID: String? = nil, now: Date = Date()) throws {
        state = try Self.randomValue()
        nonce = try Self.randomValue()
        verifier = try Self.randomValue()
        self.redirectURI = redirectURI
        self.hostID = hostID
        self.account = account
        clientID = account?.clientID ?? registeredClientID
        expiresAt = now.addingTimeInterval(600)
    }

    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

    func authorizationURL(endpoint: URL) -> URL {
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var fields = [
            "client_id": clientID ?? "dynamic_agent_client",
            "ext_agent_host_id": hostID, "response_type": "code",
            "redirect_uri": redirectURI.absoluteString,
            "scope": ChatGPTAuth.scopes, "resource": ChatGPTAuth.resource,
            "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": challenge
        ]
        if let account {
            fields["id_token_hint"] = account.tokens?.idToken
            fields["login_hint"] = account.email
            if account.tokens?.canUsePlan != true { fields["prompt"] = "consent" }
        } else if clientID == nil {
            fields["agent_name_hint"] = "Byte"
        }
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    func callback(_ url: URL, now: Date = Date()) throws -> (code: String, clientID: String) {
        guard now < expiresAt,
              url.scheme == redirectURI.scheme, url.host == redirectURI.host,
              url.port == redirectURI.port, url.path == redirectURI.path,
              url.fragment == nil, url.user == nil, url.password == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ChatGPTConnectionError("The sign-in callback is invalid or expired. Try signing in again.")
        }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else {
                throw ChatGPTConnectionError("The sign-in callback contains invalid parameters.")
            }
            values[item.name] = value
        }
        guard values["state"] == state else {
            throw ChatGPTConnectionError("The sign-in callback did not match this attempt.")
        }
        if values["error"] != nil {
            throw ChatGPTConnectionError("ChatGPT sign-in was declined. Your existing connection was kept.")
        }
        let returnedClientID = values["client_id"] ?? clientID
        guard let code = values["code"], !code.isEmpty,
              let returnedClientID, !returnedClientID.isEmpty, returnedClientID != "dynamic_agent_client",
              clientID == nil || clientID == returnedClientID else {
            throw ChatGPTConnectionError("ChatGPT did not return the expected Byte registration. Try signing in again.")
        }
        return (code, returnedClientID)
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTConnectionError("Couldn't prepare secure sign-in. Try again.")
        }
        return Data(bytes).base64URL
    }
}

struct ChatGPTIdentity {
    let subject: String
    let email: String?

    /// Verify the signature before trusting any claims. Restrict algorithms both
    /// to discovery's advertised values and the implementations supported here.
    static func verify(_ token: String, jwks: Data, algorithms: [String],
                       clientID: String, nonce: String, now: Date = Date()) throws -> Self {
        func invalid() -> ChatGPTConnectionError {
            ChatGPTConnectionError("Couldn't verify the ChatGPT account. Your existing connection was kept.")
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let claimsData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let alg = header["alg"] as? String, algorithms.contains(alg),
              let kid = header["kid"] as? String,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid }),
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == alg else { throw invalid() }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        var verified = false
        if alg == "RS256", key["kty"] as? String == "RSA",
           let n = key["n"] as? String, let modulus = Data(base64URL: n),
           let e = key["e"] as? String, let exponent = Data(base64URL: e),
           modulus.count >= 256, !exponent.isEmpty {
            let der = asn1(0x30, asn1Integer(modulus) + asn1Integer(exponent))
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            if let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) {
                verified = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                  signed as CFData, signature as CFData, nil)
            }
        } else if alg == "ES256", key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
                  let x = key["x"] as? String, let xData = Data(base64URL: x), xData.count == 32,
                  let y = key["y"] as? String, let yData = Data(base64URL: y), yData.count == 32,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + xData + yData),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            verified = publicKey.isValidSignature(sig, for: signed)
        }
        guard verified,
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              claims["nonce"] as? String == nonce,
              let sub = claims["sub"] as? String, !sub.isEmpty,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5 else { throw invalid() }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              audiences.count <= 1 || claims["azp"] as? String == clientID,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 5 else { throw invalid() }
        return Self(subject: sub, email: claims["email"] as? String)
    }

    private static func asn1Integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return asn1(0x02, bytes)
    }

    private static func asn1(_ tag: UInt8, _ data: Data) -> Data {
        var length: [UInt8] = []
        if data.count < 128 { length = [UInt8(data.count)] }
        else {
            var count = data.count
            while count > 0 { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + data
    }
}

@MainActor
final class ChatGPTAuth: ObservableObject {
    nonisolated static let resource = "https://api.openai.com/v1"
    nonisolated static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    nonisolated static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    @Published private(set) var accounts: [ChatGPTAccount] = []
    @Published private(set) var activeClientID: String?
    @Published private(set) var isSigningIn = false
    @Published var error: String?
    @Published var showPlanWelcome = false
    @Published private(set) var needsCredentialSave = false

    private let store: any APIKeyStoring
    private let defaults: UserDefaults
    private let session: URLSession
    private let credentialLock: ChatGPTCredentialLock
    private var listener: OAuthLoopbackListener?
    private var refreshes: [String: Task<String, Error>] = [:]
    private struct PendingCommit {
        let accounts: [ChatGPTAccount]
        let selectedClientID: String?
        let notice: String?
        let lease: ChatGPTCredentialLock.Lease
    }
    private var pendingCommit: PendingCommit?
    private var isUsingCredentials = false

    init(store: any APIKeyStoring = KeychainAPIKeyStore(service: "com.ronnie.byte.chatgpt", account: "accounts"),
         defaults: UserDefaults = .standard, session: URLSession = ProviderSession.shared,
         credentialLock: ChatGPTCredentialLock = ChatGPTCredentialLock()) {
        self.store = store; self.defaults = defaults; self.session = session
        self.credentialLock = credentialLock
        activeClientID = defaults.string(forKey: "byte.chatGPT.account")
        do {
            if let json = try store.read() {
                accounts = try JSONDecoder().decode([ChatGPTAccount].self, from: Data(json.utf8))
            }
            if !accounts.contains(where: { $0.clientID == activeClientID }) { activeClientID = nil }
        } catch { self.error = "Couldn't read your ChatGPT connection from Keychain. \(error.localizedDescription)" }
    }

    var activeAccount: ChatGPTAccount? { accounts.first { $0.clientID == activeClientID } }
    var isSignedIn: Bool { activeAccount?.tokens != nil }
    var canUsePlan: Bool { !needsCredentialSave && activeAccount?.tokens?.canUsePlan == true }

    var hostID: String {
        if let saved = defaults.string(forKey: "byte.chatGPT.hostID") { return saved }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: "byte.chatGPT.hostID")
        return id
    }

    func selectAccount(_ clientID: String) {
        guard accounts.contains(where: { $0.clientID == clientID }), !isSigningIn else { return }
        activeClientID = clientID
        defaults.set(clientID, forKey: "byte.chatGPT.account")
    }

    func signIn(accountID: String? = nil, openBrowser: (URL) -> Bool) async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        let readLease = try await credentialsLease()
        let oldAccount: ChatGPTAccount?
        do {
            try reloadAccounts()
            oldAccount = accountID.flatMap { id in accounts.first { $0.clientID == id } }
            if accountID != nil, oldAccount == nil {
                throw ChatGPTConnectionError("Choose a saved ChatGPT account or add a new one.")
            }
        } catch { release(readLease); throw error }
        release(readLease)
        let config = try await configuration()
        var registeredClientID = oldAccount?.clientID
        // An expired/consumed code needs a fresh browser transaction, not another
        // dynamic registration. Bound recovery so a provider failure cannot loop.
        for authorization in 0..<2 {
            let listener = OAuthLoopbackListener()
            self.listener = listener
            defer { listener.cancel(); self.listener = nil }
            let redirectURI = try await listener.start()
            let attempt = try ChatGPTOAuthAttempt(redirectURI: redirectURI, hostID: hostID,
                account: oldAccount, registeredClientID: registeredClientID)
            listener.expectedState = attempt.state
            try Task.checkCancellation()
            guard openBrowser(attempt.authorizationURL(endpoint: config.authorization_endpoint)) else {
                throw ChatGPTConnectionError("Couldn't open your browser to sign in to ChatGPT.")
            }
            let callback = try attempt.callback(try await listener.waitForCallback())
            let lease = try await credentialsLease()
            defer { release(lease) }
            try reloadAccounts()
            let response: TokenResponse
            do {
                response = try await exchange(endpoint: config.token_endpoint, fields: [
                    "grant_type": "authorization_code", "client_id": callback.clientID,
                    "code": callback.code, "code_verifier": attempt.verifier,
                    "redirect_uri": redirectURI.absoluteString, "resource": Self.resource
                ])
            } catch let error as ChatGPTAuthorizationHTTPError where error.code == "invalid_grant" && authorization == 0 {
                registeredClientID = callback.clientID
                continue
            }
            let jwks = try await get(config.jwks_uri)
            let identity = try ChatGPTIdentity.verify(response.id_token ?? "", jwks: jwks,
                algorithms: config.id_token_signing_alg_values_supported,
                clientID: callback.clientID, nonce: attempt.nonce)
            guard oldAccount == nil || oldAccount?.subject == identity.subject else {
                throw ChatGPTConnectionError("That sign-in belongs to a different account. Use Add account instead.")
            }
            let tokens = try response.tokens(previous: nil)
            try Task.checkCancellation()
            try save(ChatGPTAccount(clientID: callback.clientID, subject: identity.subject,
                email: identity.email, tokens: tokens), lease: lease, selectedClientID: callback.clientID,
                notice: tokens.canUsePlan ? nil : Self.planPermissionMessage)
            return
        }
    }

    func cancelSignIn() { listener?.cancel() }

    func accessToken(for clientID: String) async throws -> String {
        if let refresh = refreshes[clientID] { return try await refresh.value }
        let refresh = Task { @MainActor in
            let lease = try await self.credentialsLease()
            defer { self.release(lease) }
            // Even an unexpired in-memory token may have been refreshed or signed
            // out by another process. Always read the shared record under lock.
            try self.reloadAccounts()
            guard let account = self.accounts.first(where: { $0.clientID == clientID }),
                  let tokens = account.tokens else {
                throw ChatGPTConnectionError("Continue with ChatGPT to connect your plan.")
            }
            guard tokens.canUsePlan else { throw ChatGPTConnectionError(Self.planPermissionMessage) }
            if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
            do {
                let config = try await self.configuration()
                let response = try await self.exchange(endpoint: config.token_endpoint, fields: [
                    "grant_type": "refresh_token", "client_id": clientID,
                    "refresh_token": tokens.refreshToken, "resource": Self.resource
                ])
                let renewed = try response.tokens(previous: tokens)
                var updated = account
                updated.tokens = renewed
                try self.save(updated, lease: lease,
                    notice: renewed.canUsePlan ? nil : Self.planPermissionMessage)
                guard renewed.canUsePlan else { throw ChatGPTConnectionError(Self.planPermissionMessage) }
                return renewed.accessToken
            } catch let error as ChatGPTAuthorizationHTTPError {
                if error.endsSession {
                    var expired = account
                    expired.tokens = nil
                    try self.save(expired, lease: lease)
                }
                throw error
            }
        }
        refreshes[clientID] = refresh
        defer { refreshes[clientID] = nil }
        return try await refresh.value
    }

    /// Keep the verified registration and host identifier for returning sign-in.
    func signOut() async throws {
        guard let clientID = activeClientID else { return }
        // A refresh may already have rotated the server's token. Let it settle
        // and retain its replacement before choosing the token to revoke.
        if let refresh = refreshes[clientID] { _ = try? await refresh.value }
        let lease = try await credentialsLease(flushPending: false)
        defer { release(lease) }
        // A pending replacement is the only renewable token after rotation; use
        // it for revocation even if Keychain is still unable to save it.
        if pendingCommit == nil { try reloadAccounts() }
        guard let current = (pendingCommit?.accounts ?? accounts).first(where: { $0.clientID == clientID }) else { return }
        var revoked = current.tokens?.refreshToken.isEmpty ?? true
        if let tokens = current.tokens, !tokens.refreshToken.isEmpty {
            for attempt in 0..<2 {
                do {
                    let config = try await configuration()
                    if let endpoint = config.revocation_endpoint {
                        _ = try await post(endpoint, fields: ["token": tokens.refreshToken,
                            "token_type_hint": "refresh_token", "client_id": clientID])
                        revoked = true
                        break
                    }
                } catch { /* Clear locally even when the provider is unreachable. */ }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            }
        }
        var signedOut = current
        signedOut.tokens = nil
        try save(signedOut, lease: lease, notice: revoked ? nil :
            "Signed out locally. Remote disconnection wasn't confirmed; disconnect Byte in ChatGPT usage settings.")
    }

    func retryPendingSave() throws {
        guard let pending = pendingCommit else { return }
        guard !isUsingCredentials else {
            throw ChatGPTConnectionError("Your ChatGPT connection is still being updated. Try saving again when it finishes.")
        }
        try commit(pending)
        pending.lease.release()
    }

    private static let planPermissionMessage = "Signed in, but ChatGPT plan usage isn't enabled. Continue with ChatGPT again to enable it."

    private func credentialsLease(flushPending: Bool = true) async throws -> ChatGPTCredentialLock.Lease {
        let deadline = Date().addingTimeInterval(30)
        while isUsingCredentials {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw ChatGPTConnectionError("Your ChatGPT connection is still being updated. Try again when it finishes.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        isUsingCredentials = true
        do {
            if let pending = pendingCommit {
                if flushPending { try commit(pending) }
                return pending.lease
            }
            return try await credentialLock.acquire()
        } catch {
            isUsingCredentials = false
            throw error
        }
    }

    private func release(_ lease: ChatGPTCredentialLock.Lease) {
        // Keep the lock while a rotated token is waiting for protected storage.
        // Other processes must not reuse the stale token still in Keychain.
        if pendingCommit?.lease !== lease { lease.release() }
        isUsingCredentials = false
    }

    private func reloadAccounts() throws {
        let loaded = try store.read().map { try JSONDecoder().decode([ChatGPTAccount].self, from: Data($0.utf8)) } ?? []
        accounts = loaded
    }

    private func save(_ account: ChatGPTAccount, lease: ChatGPTCredentialLock.Lease,
                      selectedClientID: String? = nil, notice: String? = nil) throws {
        var updated = pendingCommit?.accounts ?? accounts
        if let index = updated.firstIndex(where: { $0.clientID == account.clientID }) { updated[index] = account }
        else { updated.append(account) }
        try commit(PendingCommit(accounts: updated, selectedClientID: selectedClientID, notice: notice, lease: lease))
    }

    private func commit(_ pending: PendingCommit) throws {
        pendingCommit = pending
        // Commit to protected storage before publishing the connection as usable.
        do {
            let data = try JSONEncoder().encode(pending.accounts)
            try store.save(String(decoding: data, as: UTF8.self))
        } catch {
            needsCredentialSave = true
            let message = "Couldn't save your ChatGPT connection to Keychain. Unlock Keychain or restore access, then choose Retry Keychain save. \(error.localizedDescription)"
            self.error = message
            throw ChatGPTConnectionError(message)
        }
        pendingCommit = nil
        needsCredentialSave = false
        accounts = pending.accounts
        error = pending.notice
        if let clientID = pending.selectedClientID {
            activeClientID = clientID
            defaults.set(clientID, forKey: "byte.chatGPT.account")
            if canUsePlan, !defaults.bool(forKey: "byte.chatGPT.welcomed.\(clientID)") {
                showPlanWelcome = true
                defaults.set(true, forKey: "byte.chatGPT.welcomed.\(clientID)")
            }
        }
    }

    private struct Configuration: Decodable {
        let issuer: String
        let authorization_endpoint: URL
        let token_endpoint: URL
        let jwks_uri: URL
        let revocation_endpoint: URL?
        let id_token_signing_alg_values_supported: [String]
    }

    private func configuration() async throws -> Configuration {
        let url = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
        let config = try JSONDecoder().decode(Configuration.self, from: try await get(url))
        guard config.issuer == "https://auth.openai.com",
              [config.authorization_endpoint, config.token_endpoint, config.jwks_uri]
                .allSatisfy(Self.isAuthURL),
              config.revocation_endpoint.map(Self.isAuthURL) ?? true else {
            throw ChatGPTConnectionError("ChatGPT returned an unsupported sign-in configuration.")
        }
        return config
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let id_token: String?
        let token_type: String?
        let expires_in: Double?
        let scope: String?

        func tokens(previous: ChatGPTTokens?) throws -> ChatGPTTokens {
            let granted = scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
            let enabled = granted.contains("chatgpt.tokens.use.direct") && granted.contains("resource.invoke")
            guard let id = id_token ?? previous?.idToken, !id.isEmpty,
                  !enabled || (token_type?.lowercased() == "bearer" && !(access_token ?? "").isEmpty &&
                    !(refresh_token ?? "").isEmpty && (expires_in ?? 0) > 0) else {
                throw ChatGPTConnectionError("ChatGPT returned incomplete credentials. Continue with ChatGPT again.")
            }
            return ChatGPTTokens(accessToken: access_token ?? "", refreshToken: refresh_token ?? "", idToken: id,
                expiresAt: Date().addingTimeInterval(expires_in ?? 0), scopes: granted)
        }
    }

    private func exchange(endpoint: URL, fields: [String: String]) async throws -> TokenResponse {
        try JSONDecoder().decode(TokenResponse.self, from: try await post(endpoint, fields: fields))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await perform(request)
    }

    private func post(_ url: URL, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData(fields)
        return try await perform(request)
    }

    nonisolated static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url, Self.isAuthURL(url) else {
            throw ChatGPTConnectionError("ChatGPT returned an unexpected sign-in response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Never echo token-endpoint bodies or authorization URLs into the UI.
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = body?["error"] as? String ?? (body?["error"] as? [String: Any])?["code"] as? String
            throw ChatGPTAuthorizationHTTPError(status: http.statusCode, code: code)
        }
        return data
    }

    nonisolated private static func isAuthURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        let base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}
