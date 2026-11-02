//
//  ChatGPTSignInTests.swift
//  swiftpy-llm
//

import Testing
import Foundation
import FoundationModels
import Security
@testable import OpenAI

/// Answers auth.openai.com with canned discovery, keys and tokens.
final class MockAuth: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var forms: [String: [String: String]] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "auth.openai.com" || request.url?.host == "keys.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if let body = bodyData() {
            var form: [String: String] = [:]
            for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { form[parts[0]] = parts[1] }
            }
            Self.forms[path] = form
        }
        let (status, text) = Self.routes[path] ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        var data = Data()
        stream.open()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read > 0 { data.append(buffer, count: read) }
        }
        stream.close()
        return data
    }

    override func stopLoading() {}
}

@MainActor
final class MemoryCredentialStore: ChatGPTCredentialStore {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data?) { self.data = data }
}

/// An RSA key that signs ID tokens as OpenAI's would.
struct TestSigner {
    let privateKey: SecKey
    let jwks: String

    init() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let (modulus, exponent) = try #require(Self.integers(der))
        jwks = #"{"keys":[{"kty":"RSA","kid":"test","alg":"RS256","n":"\#(modulus.base64URLEncoded)","e":"\#(exponent.base64URLEncoded)"}]}"#
    }

    func idToken(_ claims: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"RS256","kid":"test","typ":"JWT"}"#.utf8).base64URLEncoded
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URLEncoded
        let signed = Data("\(header).\(payload)".utf8)
        let signature = try #require(SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, nil
        ) as Data?)
        return "\(header).\(payload).\(signature.base64URLEncoded)"
    }

    /// PKCS #1's two integers: SEQUENCE { INTEGER n, INTEGER e }.
    private static func integers(_ der: Data) -> (Data, Data)? {
        var index = der.startIndex
        func length() -> Int {
            let first = Int(der[index]); index += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7F) { value = value << 8 | Int(der[index]); index += 1 }
            return value
        }
        func integer() -> Data {
            index += 1 // 0x02
            let count = length()
            defer { index += count }
            return Data(der[index..<index + count])
        }
        guard der[index] == 0x30 else { return nil }
        index += 1
        _ = length()
        return (integer(), integer())
    }
}

extension OpenAISuite {
    @MainActor
    @Suite(.serialized)
    struct ChatGPTSignInTests {
        let account = ChatGPTAccount.shared
        let store = MemoryCredentialStore()

        init() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockAuth.self]
            account.urlSession = URLSession(configuration: configuration)
            account.store = store
            account.appName = "PyPrompt"
            account.defaults = UserDefaults(suiteName: "ChatGPTSignInTests")!
            account.defaults.removeObject(forKey: "ChatGPTHostID")
            MockAuth.routes = [:]
            MockAuth.forms = [:]
        }

        private func clientID(in url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value
        }

        @Test func pkceIsTheVerifiersSHA256InBase64URL() {
            // From Python: base64.urlsafe_b64encode(hashlib.sha256(verifier).digest()), unpadded.
            #expect(ChatGPTAuthorization.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFqEjXk")
                == "_9mo02U_rnIEiDT8PGR1bbVIFlBFHB-QIUCGlwZYzQU")
        }

        @Test func firstSignInRegistersAndALaterOneReusesTheClient() throws {
            let attempt = ChatGPTAuthorization.Attempt()
            let first = ChatGPTAuthorization.authorizeURL(
                attempt: attempt, clientID: nil, hostID: "urn:uuid:host",
                redirectURI: "http://127.0.0.1:1455/auth/callback", appName: "PyPrompt"
            )
            let query = Dictionary(uniqueKeysWithValues: try #require(
                URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems
            ).map { ($0.name, $0.value ?? "") })
            #expect(query["client_id"] == "dynamic_agent_client")
            #expect(query["agent_name_hint"] == "PyPrompt")
            #expect(query["ext_agent_host_id"] == "urn:uuid:host")
            #expect(query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
            #expect(query["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
            #expect(query["resource"] == "https://api.openai.com/v1")
            #expect(query["code_challenge"] == attempt.challenge)
            #expect(query["code_challenge_method"] == "S256")
            #expect(query["state"] == attempt.state && query["nonce"] == attempt.nonce)
            // Each value is percent-encoded, spaces too.
            #expect(first.absoluteString.contains("scope=openid%20profile"))

            let later = ChatGPTAuthorization.authorizeURL(
                attempt: attempt, clientID: "oaiapp_1", hostID: "urn:uuid:host",
                redirectURI: "http://127.0.0.1:1455/auth/callback", appName: "PyPrompt",
                idTokenHint: "hint", loginHint: "a@b.c"
            )
            let laterQuery = try #require(URLComponents(url: later, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(clientID(in: later) == "oaiapp_1")
            #expect(!laterQuery.contains { $0.name == "agent_name_hint" })
            #expect(laterQuery.contains { $0.name == "id_token_hint" && $0.value == "hint" })
            #expect(laterQuery.contains { $0.name == "login_hint" && $0.value == "a@b.c" })
        }

        @Test func theListenerTakesTheCallbackAndRedirectsToTheApp() async throws {
            let listener = try await LoopbackListener.start(preferredPort: 0)
            defer { listener.cancel() }
            #expect(listener.redirectURI.hasPrefix("http://127.0.0.1:"))

            let waiting = Task { try await listener.callback(completion: URL(string: "swiftpy-chatgpt://signed-in")!) }
            let url = URL(string: "\(listener.redirectURI)?code=abc&state=xyz&client_id=oaiapp_1")!
            let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
            let (_, response) = try await session.data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 302)
            #expect(http.value(forHTTPHeaderField: "Location") == "swiftpy-chatgpt://signed-in")

            let query = try await waiting.value
            #expect(query == ["code": "abc", "state": "xyz", "client_id": "oaiapp_1"])
        }

        @Test func signsInValidatesTheIDTokenAndKeepsTheTokens() async throws {
            let signer = try TestSigner()
            MockAuth.routes["/.well-known/openid-configuration"] = (200, #"{"jwks_uri":"https://keys.test/jwks","revocation_endpoint":"https://auth.openai.com/oauth/revoke"}"#)
            MockAuth.routes["/jwks"] = (200, signer.jwks)

            account.authorize = { url, _ in
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value = { (name: String) in query.first { $0.name == name }?.value ?? "" }
                let idToken = try signer.idToken([
                    "iss": "https://auth.openai.com", "sub": "user-1", "aud": ["oaiapp_1"],
                    "exp": Date().timeIntervalSince1970 + 600, "nonce": value("nonce"), "email": "ada@example.com",
                ])
                MockAuth.routes["/api/accounts/oauth/token"] = (200, #"{"access_token":"at-1","refresh_token":"rt-1","id_token":"\#(idToken)","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#)
                return ["code": "code-1", "state": value("state"), "client_id": "oaiapp_1"]
            }

            let email = try await account.signIn()
            #expect(email == "ada@example.com")
            #expect(account.isSignedIn)
            #expect(account.email == "ada@example.com")
            let record = try #require(account.record)
            #expect(record.clientID == "oaiapp_1")
            #expect(record.accessToken == "at-1" && record.refreshToken == "rt-1")

            let exchange = try #require(MockAuth.forms["/api/accounts/oauth/token"])
            #expect(exchange["grant_type"] == "authorization_code")
            #expect(exchange["client_id"] == "oaiapp_1")
            #expect(exchange["code"] == "code-1")
            #expect(exchange["resource"] == "https://api.openai.com/v1")
            #expect(exchange["code_verifier"]?.isEmpty == false)

            // Signing out revokes the refresh token, and keeps the registration.
            MockAuth.routes["/oauth/revoke"] = (200, "")
            await account.signOut()
            #expect(MockAuth.forms["/oauth/revoke"]?["token"] == "rt-1")
            #expect(!account.isSignedIn)
            #expect(account.record?.clientID == "oaiapp_1")
            #expect(account.record?.refreshToken == nil)
        }

        @Test func aStateThatDoesntMatchIsRejected() async throws {
            account.authorize = { _, _ in ["code": "c", "state": "forged", "client_id": "oaiapp_1"] }
            await #expect(throws: ChatGPTSignInError.self) { try await account.signIn() }
            #expect(account.record == nil)
        }

        @Test func refreshesNearExpiryAndForgetsAnUnusableToken() async throws {
            account.record = .init(
                clientID: "oaiapp_1", accessToken: "old", refreshToken: "rt-1",
                expiresAt: Date(timeIntervalSinceNow: 30), scopes: [ChatGPTAuthorization.planScope]
            )
            MockAuth.routes["/api/accounts/oauth/token"] = (200, #"{"access_token":"new","refresh_token":"rt-2","expires_in":3600}"#)
            #expect(try await account.accessToken() == "new")
            #expect(account.record?.refreshToken == "rt-2")
            let refresh = try #require(MockAuth.forms["/api/accounts/oauth/token"])
            #expect(refresh["grant_type"] == "refresh_token" && refresh["refresh_token"] == "rt-1")

            // Current: no request.
            MockAuth.forms = [:]
            #expect(try await account.accessToken() == "new")
            #expect(MockAuth.forms.isEmpty)

            account.record?.expiresAt = Date(timeIntervalSinceNow: -1)
            MockAuth.routes["/api/accounts/oauth/token"] = (400, #"{"error":"invalid_grant","error_description":"Reused."}"#)
            do {
                _ = try await account.accessToken()
                Issue.record("An unusable refresh token didn't throw")
            } catch ChatGPTSignInError.signInExpired {
                #expect(account.record?.refreshToken == nil)
                #expect(!account.isSignedIn)
            }
        }

        @Test func signedInOnlyWithPlanUse() {
            account.record = .init(
                clientID: "oaiapp_1", accessToken: "at", refreshToken: "rt",
                expiresAt: Date(timeIntervalSinceNow: 600), scopes: [ChatGPTAuthorization.planScope]
            )
            #expect(account.isSignedIn)
            // Without plan use, there's nothing to run on.
            account.record?.scopes = ["openid"]
            #expect(!account.isSignedIn)
        }

        @Test func aSignedInRequestUsesThePlansRules() async throws {
            account.record = .init(
                clientID: "oaiapp_1", accessToken: "plan-token", refreshToken: "rt",
                expiresAt: Date(timeIntervalSinceNow: 600), scopes: [ChatGPTAuthorization.planScope]
            )
            MockResponses.reset { _, count in
                if count == 1 {
                    (200, #"""
                    data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","namespace":"app"}}

                    data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"city\":\"Paris\"}"}

                    data: {"type":"response.completed","response":{}}

                    """#)
                } else {
                    (200, #"""
                    data: {"type":"response.output_text.delta","item_id":"m","delta":"Sunny."}

                    data: {"type":"response.completed","response":{}}

                    """#)
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockResponses.self]
            var model = ResponsesLanguageModel(name: "gpt-test", credential: .chatGPTPlan, url: URL(string: "https://mock-openai.test/v1")!)
            model.urlSession = URLSession(configuration: configuration)

            let session = LanguageModelSession(model: model, tools: [WeatherTool()])
            let response = try await session.respond(to: "Weather?", options: GenerationOptions(maximumResponseTokens: 100))
            #expect(response.content == "Sunny.")

            let first = try #require(MockResponses.bodies.first)
            #expect(first["max_output_tokens"] == nil)
            let tools = try #require(first["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            #expect(tools[0]["type"] as? String == "namespace")
            #expect(tools[0]["name"] as? String == "app")
            #expect((tools[0]["tools"] as? [[String: Any]])?.first?["name"] as? String == "get_weather")

            let second = try #require(MockResponses.bodies.last?["input"] as? [[String: Any]])
            let call = try #require(second.first { $0["type"] as? String == "function_call" })
            #expect(call["namespace"] as? String == "app")
            #expect(MockResponses.authorizations.last == "Bearer plan-token")
        }

        @Test func planErrorsReadAsTheirRecovery() {
            let expired = ResponsesLanguageModel.Executor.error(
                statusCode: 401, body: Data(#"{"detail":"Not authorized."}"#.utf8), usesPlan: true
            )
            guard case .signInExpired = expired as? ChatGPTSignInError else {
                Issue.record("\(expired)")
                return
            }
            let limit = ResponsesLanguageModel.Executor.error(
                statusCode: 429,
                body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Limit."}}"#.utf8),
                usesPlan: true
            )
            #expect(limit.localizedDescription.contains("ChatGPT Settings"))
            let unavailable = ResponsesLanguageModel.Executor.error(
                statusCode: 503,
                body: Data(#"{"error":{"code":"subscription_sharing_usage_unavailable","message":"Later."}}"#.utf8),
                usesPlan: true
            )
            guard case .rateLimited = unavailable as? LanguageModelError else {
                Issue.record("\(unavailable)")
                return
            }
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
