//
//  ChatGPTAccount.swift
//  swiftpy-llm
//

import Foundation
import AuthenticationServices
import Security
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The ChatGPT account signed in with, whose plan the models use instead of
/// an API key. Its tokens stay in this device's keychain, out of Python's
/// reach; a rotating refresh token must not sync to another device.
@MainActor
public final class ChatGPTAccount {
    public static let shared = ChatGPTAccount()

    /// The host of the app-scheme URL that ends the sign-in sheet, such as
    /// `pyprompt://chatgpt-signed-in`, which the app's own URL handling skips.
    public nonisolated static let callbackHost = "chatgpt-signed-in"

    /// Whether signing in is offered; without it, it's as if signed out.
    public internal(set) var isEnabled = false

    var store: any ChatGPTCredentialStore = KeychainCredentialStore()
    var defaults = UserDefaults.standard
    var urlSession = URLSession(configuration: .ephemeral)
    /// Presents the browser and returns the loopback callback's query.
    var authorize: @MainActor (_ url: URL, _ listener: LoopbackListener) async throws -> [String: String] = WebSignIn.run
    var appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "SwiftPy"

    private var jwks: ChatGPTAuthorization.JWKS?
    private var refreshing: Task<String, any Error>?

    private static let hostIDKey = "ChatGPTHostID"
    /// Renews this long before the access token expires.
    private static let refreshMargin: TimeInterval = 120

    /// What's kept for the account: the registration, which outlives a
    /// sign-out, and the tokens, which don't.
    struct Record: Codable, Equatable {
        var clientID: String
        var subject: String?
        var email: String?
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String] = []
    }

    var record: Record? {
        get { store.load().flatMap { try? JSONDecoder().decode(Record.self, from: $0) } }
        set { store.save(newValue.flatMap { try? JSONEncoder().encode($0) }) }
    }

    public var isSignedIn: Bool {
        guard isEnabled, let record, record.accessToken != nil else { return false }
        return record.scopes.contains(ChatGPTAuthorization.planScope)
    }

    /// The signed-in account's email.
    public var email: String? {
        isSignedIn ? record?.email : nil
    }

    /// This device's stable, opaque host ID, made before its first sign-in.
    var hostID: String {
        if let saved = defaults.string(forKey: Self.hostIDKey) { return saved }
        let made = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(made, forKey: Self.hostIDKey)
        return made
    }

    // MARK: Signing in

    /// Signs in in the browser, registering this app the first time, and
    /// returns the account's email.
    @discardableResult
    public func signIn() async throws -> String {
        let saved = record
        let attempt = ChatGPTAuthorization.Attempt()
        let listener = try await LoopbackListener.start()
        defer { listener.cancel() }

        let url = ChatGPTAuthorization.authorizeURL(
            attempt: attempt,
            clientID: saved?.clientID,
            hostID: hostID,
            redirectURI: listener.redirectURI,
            appName: appName,
            idTokenHint: saved?.idToken,
            loginHint: saved?.email
        )
        let callback = try await authorize(url, listener)

        guard callback["state"] == attempt.state else { throw ChatGPTSignInError.stateMismatch }
        if callback["error"] == "access_denied" { throw ChatGPTSignInError.planNotAllowed }
        if let error = callback["error"] {
            throw ChatGPTSignInError.oauth(code: error, description: callback["error_description"] ?? "")
        }
        guard let code = callback["code"] else { throw ChatGPTSignInError.missingClientID }

        let clientID: String
        if let saved {
            // A returning sign-in keeps its registration.
            if let returned = callback["client_id"], returned != saved.clientID { throw ChatGPTSignInError.otherAccount }
            clientID = saved.clientID
        } else {
            guard let issued = callback["client_id"], issued != ChatGPTAuthorization.registrationClientID else {
                throw ChatGPTSignInError.missingClientID
            }
            clientID = issued
        }

        let tokens = try await ChatGPTAuthorization.requestTokens([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", attempt.verifier),
            ("redirect_uri", listener.redirectURI),
            ("resource", ChatGPTAuthorization.resource),
        ], session: urlSession)

        guard let idToken = tokens.idToken else { throw ChatGPTSignInError.invalidIDToken("none was returned") }
        let claims = try ChatGPTAuthorization.validate(
            idToken: idToken, clientID: clientID, nonce: attempt.nonce, keys: try await keys()
        )
        if let subject = saved?.subject, subject != claims.sub { throw ChatGPTSignInError.otherAccount }

        let scopes = (tokens.scope ?? callback["scope"] ?? "").split(separator: " ").map(String.init)
        var signedIn = Record(clientID: clientID, subject: claims.sub, email: claims.email, idToken: idToken)
        // Without plan use there's nothing to run on; the registration stays.
        guard scopes.contains(ChatGPTAuthorization.planScope) else {
            record = signedIn
            throw ChatGPTSignInError.planNotAllowed
        }
        signedIn.accessToken = tokens.accessToken
        signedIn.refreshToken = tokens.refreshToken
        signedIn.expiresAt = Date(timeIntervalSinceNow: TimeInterval(tokens.expiresIn ?? 3600))
        signedIn.scopes = scopes
        record = signedIn
        return claims.email ?? claims.sub
    }

    /// Revokes the renewable session and forgets the tokens, keeping the
    /// registration for the next sign-in.
    public func signOut() async {
        refreshing?.cancel()
        refreshing = nil
        guard var signedOut = record else { return }
        if let refreshToken = signedOut.refreshToken,
           let endpoint = try? await ChatGPTAuthorization.discovery(session: urlSession).revocationEndpoint {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ChatGPTAuthorization.formBody([
                ("token", refreshToken),
                ("token_type_hint", "refresh_token"),
                ("client_id", signedOut.clientID),
            ])
            _ = try? await urlSession.data(for: request)
        }
        signedOut.accessToken = nil
        signedOut.refreshToken = nil
        signedOut.idToken = nil
        signedOut.expiresAt = nil
        signedOut.scopes = []
        record = signedOut
    }

    // MARK: Tokens

    /// A current access token, renewed near its expiry; one renewal at a
    /// time, as each replaces the refresh token.
    func accessToken() async throws -> String {
        guard isEnabled, let current = record, let token = current.accessToken else {
            throw ChatGPTSignInError.notSignedIn
        }
        if let expiresAt = current.expiresAt, expiresAt.timeIntervalSinceNow > Self.refreshMargin {
            return token
        }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard var current = record, let refreshToken = current.refreshToken else {
            throw ChatGPTSignInError.signInExpired
        }
        let tokens: ChatGPTAuthorization.Tokens
        do {
            tokens = try await ChatGPTAuthorization.requestTokens([
                ("grant_type", "refresh_token"),
                ("client_id", current.clientID),
                ("refresh_token", refreshToken),
                ("resource", ChatGPTAuthorization.resource),
            ], session: urlSession)
        } catch ChatGPTSignInError.oauth(let code, _) where Self.unusableRefreshCodes.contains(code) {
            current.accessToken = nil
            current.refreshToken = nil
            current.expiresAt = nil
            record = current
            throw ChatGPTSignInError.signInExpired
        }
        current.accessToken = tokens.accessToken
        current.refreshToken = tokens.refreshToken ?? refreshToken
        current.expiresAt = Date(timeIntervalSinceNow: TimeInterval(tokens.expiresIn ?? 3600))
        if let scope = tokens.scope { current.scopes = scope.split(separator: " ").map(String.init) }
        record = current
        return tokens.accessToken
    }

    private static let unusableRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
    ]

    private func keys() async throws -> ChatGPTAuthorization.JWKS {
        if let jwks { return jwks }
        let discovery = try await ChatGPTAuthorization.discovery(session: urlSession)
        let (data, _) = try await urlSession.data(from: discovery.jwksURI)
        let fetched = try JSONDecoder().decode(ChatGPTAuthorization.JWKS.self, from: data)
        jwks = fetched
        return fetched
    }
}

// MARK: - Storage

/// Where the account's record is kept: the device's keychain, or memory in tests.
@MainActor
protocol ChatGPTCredentialStore {
    func load() -> Data?
    func save(_ data: Data?)
}

/// A device-only keychain item, apart from `keychain`'s secrets so Python
/// can't list or read it.
@MainActor
struct KeychainCredentialStore: ChatGPTCredentialStore {
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.felfoldy.swiftpy.chatgpt",
        kSecAttrAccount as String: "account",
    ]

    func load() -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data?) {
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - Browser

/// The sign-in sheet: OpenAI's page in the system browser, which redirects
/// to the loopback listener; its reply's redirect closes the sheet.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The app's own URL scheme, such as `pyprompt`, so the browser goes back
    /// to it by name; a scheme of its own without one.
    static let callbackScheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = types?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return schemes?.first ?? "swiftpy-chatgpt"
    }()

    static func run(_ url: URL, listener: LoopbackListener) async throws -> [String: String] {
        let presenter = WebSignIn(anchor: keyWindow())
        // Called on AuthenticationServices' own queue, not main.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable _, error in
            // Closed before the callback arrived.
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                listener.finish(throwing: ChatGPTSignInError.cancelled)
            } else if let error {
                listener.finish(throwing: error)
            }
        }
        session.presentationContextProvider = presenter
        guard session.start() else { throw ChatGPTSignInError.cancelled }
        let completion = URL(string: "\(callbackScheme)://\(ChatGPTAccount.callbackHost)")!
        // The session holds its provider weakly.
        defer { withExtendedLifetime(presenter) {} }
        do {
            return try await withTaskCancellationHandler {
                try await listener.callback(completion: completion)
            } onCancel: {
                listener.finish(throwing: CancellationError())
            }
        } catch {
            session.cancel()
            throw error
        }
    }

    /// The window the sheet shows over, picked on main before it starts.
    private nonisolated(unsafe) let anchor: ASPresentationAnchor

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    private static func keyWindow() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }

    // AuthenticationServices may ask from its own queue.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
