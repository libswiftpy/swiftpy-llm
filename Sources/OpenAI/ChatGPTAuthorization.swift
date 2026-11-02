//
//  ChatGPTAuthorization.swift
//  swiftpy-llm
//

import Foundation
import CryptoKit
import Network
import Security
import Synchronization

/// Sign in with ChatGPT's OAuth pieces, as OpenAI's open-source flow has them:
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
enum ChatGPTAuthorization {
    static let issuer = "https://auth.openai.com"
    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// The scope that lets requests use the user's ChatGPT plan.
    static let planScope = "chatgpt.tokens.use.direct"
    /// The client ID a first sign-in registers through; never saved.
    static let registrationClientID = "dynamic_agent_client"
    static let callbackPath = "/auth/callback"

    /// One attempt's secrets, fresh each time.
    struct Attempt {
        var state = randomToken()
        var nonce = randomToken()
        var verifier = randomToken()

        var challenge: String { ChatGPTAuthorization.challenge(for: verifier) }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    /// PKCE's S256 challenge.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    /// The authorize URL: a first registration without a client ID, a
    /// returning sign-in with the saved one and its hints.
    static func authorizeURL(
        attempt: Attempt,
        clientID: String?,
        hostID: String,
        redirectURI: String,
        appName: String,
        idTokenHint: String? = nil,
        loginHint: String? = nil
    ) -> URL {
        var parameters: [(String, String)] = [
            ("client_id", clientID ?? registrationClientID),
            ("ext_agent_host_id", hostID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("resource", resource),
            ("state", attempt.state),
            ("nonce", attempt.nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", attempt.challenge),
        ]
        if clientID == nil {
            parameters.append(("agent_name_hint", appName))
        } else {
            if let idTokenHint { parameters.append(("id_token_hint", idTokenHint)) }
            if let loginHint { parameters.append(("login_hint", loginHint)) }
        }
        let query = parameters.map { "\($0)=\(encoded($1))" }.joined(separator: "&")
        return URL(string: authorizeURL.absoluteString + "?" + query)!
    }

    static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\($0)=\(encoded($1))" }.joined(separator: "&").utf8)
    }

    // MARK: Tokens

    struct Tokens: Decodable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresIn: Int?
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    struct OAuthError: Decodable {
        var error: String
        var errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    /// Posts a grant to the token endpoint.
    static func requestTokens(_ fields: [(String, String)], session: URLSession) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(fields)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let error = try? JSONDecoder().decode(OAuthError.self, from: data)
            throw ChatGPTSignInError.oauth(
                code: error?.error ?? "http_\(status)",
                description: error?.errorDescription ?? String(decoding: data, as: UTF8.self)
            )
        }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    // MARK: Discovery

    struct Discovery: Decodable {
        var jwksURI: URL
        var revocationEndpoint: URL?

        enum CodingKeys: String, CodingKey {
            case jwksURI = "jwks_uri"
            case revocationEndpoint = "revocation_endpoint"
        }
    }

    static func discovery(session: URLSession) async throws -> Discovery {
        let (data, _) = try await session.data(from: discoveryURL)
        return try JSONDecoder().decode(Discovery.self, from: data)
    }

    // MARK: ID token

    struct Claims: Decodable {
        var iss: String
        var sub: String
        var aud: [String]
        var exp: Double
        var nonce: String?
        var email: String?

        enum CodingKeys: String, CodingKey { case iss, sub, aud, exp, nonce, email }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            iss = try container.decode(String.self, forKey: .iss)
            sub = try container.decode(String.self, forKey: .sub)
            // A single audience or several.
            if let audiences = try? container.decode([String].self, forKey: .aud) {
                aud = audiences
            } else {
                aud = [try container.decode(String.self, forKey: .aud)]
            }
            exp = try container.decode(Double.self, forKey: .exp)
            nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
            email = try container.decodeIfPresent(String.self, forKey: .email)
        }
    }

    struct JWKS: Decodable {
        var keys: [Key]

        struct Key: Decodable {
            var kid: String?
            var kty: String
            var n: String?
            var e: String?
        }
    }

    /// The ID token's claims, once its RS256 signature checks out against
    /// OpenAI's keys and it is this attempt's, for this client, and current.
    static func validate(
        idToken: String,
        clientID: String,
        nonce: String,
        keys: JWKS,
        now: Date = Date()
    ) throws -> Claims {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URLEncoded: parts[0]),
              let payload = Data(base64URLEncoded: parts[1]),
              let signature = Data(base64URLEncoded: parts[2]),
              let header = try? JSONDecoder().decode([String: String].self, from: headerData),
              header["alg"] == "RS256"
        else { throw ChatGPTSignInError.invalidIDToken("it isn't an RS256 token") }

        let key = keys.keys.first { $0.kty == "RSA" && (header["kid"] == nil || $0.kid == header["kid"]) }
        guard let key, let modulus = key.n.flatMap(Data.init(base64URLEncoded:)),
              let exponent = key.e.flatMap(Data.init(base64URLEncoded:)),
              let publicKey = rsaPublicKey(modulus: modulus, exponent: exponent)
        else { throw ChatGPTSignInError.invalidIDToken("no matching key") }

        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(
            publicKey, .rsaSignatureMessagePKCS1v15SHA256,
            signed as CFData, signature as CFData, nil
        ) else { throw ChatGPTSignInError.invalidIDToken("its signature doesn't match") }

        let claims = try JSONDecoder().decode(Claims.self, from: payload)
        guard claims.iss == issuer else { throw ChatGPTSignInError.invalidIDToken("wrong issuer") }
        guard claims.aud.contains(clientID) else { throw ChatGPTSignInError.invalidIDToken("wrong audience") }
        guard claims.exp > now.timeIntervalSince1970 else { throw ChatGPTSignInError.invalidIDToken("it expired") }
        guard claims.nonce == nonce else { throw ChatGPTSignInError.invalidIDToken("wrong nonce") }
        return claims
    }

    /// An RSA key from its modulus and exponent, as PKCS #1 DER.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func integer(_ bytes: Data) -> Data {
            var bytes = Data(bytes.drop { $0 == 0 })
            // A leading high bit would read as negative.
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + derLength(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + derLength(body.count) + body
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    private static func derLength(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

public enum ChatGPTSignInError: LocalizedError {
    case cancelled
    /// The user didn't allow PyPrompt to use their ChatGPT plan.
    case planNotAllowed
    case stateMismatch
    case missingClientID
    case otherAccount
    case invalidIDToken(String)
    case oauth(code: String, description: String)
    /// The sign-in can't be renewed; sign in again.
    case signInExpired
    case notSignedIn

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Signing in with ChatGPT was cancelled."
        case .planNotAllowed: "ChatGPT plan use wasn't allowed. Sign in again and allow it, or use an OpenAI API key."
        case .stateMismatch: "The sign-in reply didn't match the request. Try signing in again."
        case .missingClientID: "ChatGPT didn't finish registering this app. Try signing in again."
        case .otherAccount: "The sign-in returned a different ChatGPT account than the one selected."
        case .invalidIDToken(let reason): "ChatGPT's sign-in couldn't be verified: \(reason)."
        case .oauth(let code, let description): "ChatGPT sign-in failed (\(code)): \(description)"
        case .signInExpired: "Your ChatGPT sign-in has expired. Sign in again with `chatgpt.sign_in()`."
        case .notSignedIn: "Not signed in with ChatGPT."
        }
    }
}

// MARK: - Loopback callback

/// The `http://127.0.0.1:<port>/auth/callback` listener OpenAI redirects to.
/// It answers with a redirect to `completion`, which ends the web
/// authentication session as a custom-scheme callback would.
final class LoopbackListener: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ChatGPT sign-in callback")
    private let state = Mutex<State>(State())
    let port: UInt16

    private struct State {
        var result: Result<[String: String], any Error>?
        var continuation: CheckedContinuation<[String: String], any Error>?
        var completion: URL?
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    var redirectURI: String { "http://127.0.0.1:\(port)\(ChatGPTAuthorization.callbackPath)" }

    /// Listens on `preferredPort`, or any free one when it's taken.
    static func start(preferredPort: UInt16 = 1455) async throws -> LoopbackListener {
        do {
            return try await start(port: NWEndpoint.Port(rawValue: preferredPort)!)
        } catch {
            return try await start(port: .any)
        }
    }

    private static func start(port: NWEndpoint.Port) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = Mutex<CheckedContinuation<UInt16, any Error>?>(nil)
        let queue = DispatchQueue(label: "ChatGPT sign-in listener start")
        let boundPort = try await withCheckedThrowingContinuation { continuation in
            ready.withLock { $0 = continuation }
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.withLock { $0.take() }?.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    ready.withLock { $0.take() }?.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let loopback = LoopbackListener(listener: listener, port: boundPort)
        listener.newConnectionHandler = { [weak loopback] connection in
            loopback?.handle(connection)
        }
        return loopback
    }

    /// The callback's query, once the browser reaches it.
    func callback(completion: URL) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<[String: String], any Error>? in
                state.completion = completion
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    /// Ends the wait, as when the user closes the sign-in sheet.
    func finish(throwing error: any Error) {
        deliver(.failure(error))
    }

    func cancel() {
        listener.cancel()
    }

    private func deliver(_ result: Result<[String: String], any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<[String: String], any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            return state.continuation.take()
        }
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if isComplete || error != nil || buffer.count > 65_536 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
        let components = URLComponents(string: target)
        let response: String
        if components?.path == ChatGPTAuthorization.callbackPath {
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let completion = state.withLock { $0.completion }
            if let completion {
                response = "HTTP/1.1 302 Found\r\nLocation: \(completion.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                let body = "You can close this window."
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            }
            deliver(.success(query))
        } else {
            response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
