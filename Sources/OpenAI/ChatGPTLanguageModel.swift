//
//  ChatGPTLanguageModel.swift
//  swiftpy-llm
//

import SwiftPy
import Agents
import FoundationModels

/// A ChatGPT model, reached through OpenAI's Responses API with an OpenAI API
/// key from the keychain.
@Scriptable(base: .LanguageModel)
@MainActor
public final class ChatGPTLanguageModel {
    /// The model's ID, such as `"gpt-6.1-sol"`.
    public let name: String

    private let apiKey: Secret?

    /// A ChatGPT model. Prefer ``chatgpt.sol`` and the other functions of ``chatgpt``.
    ///
    /// name: The model's ID, such as "gpt-6.1-sol".
    /// api_key: The secret holding an OpenAI API key, from ``keychain.secret``. Signed in with ChatGPT, it's not needed.
    public init(name: String, apiKey: Secret? = nil) {
        self.name = name
        self.apiKey = apiKey
    }
}

extension ChatGPTLanguageModel {
    /// What a missing key is asked for with.
    public nonisolated static let keyPrompt = "Paste an OpenAI API key from [platform.openai.com](https://platform.openai.com/api-keys)."
}

extension ChatGPTLanguageModel: CustomStringConvertible {
    public nonisolated var description: String {
        "<ChatGPTLanguageModel name=\"\(name)\">"
    }
}

extension ChatGPTLanguageModel: ModelProvider {
    package func resolve() throws(PythonError) -> (model: any FoundationModels.LanguageModel, name: String, reasons: Bool) {
        // The signed-in plan before any key.
        if ChatGPTAccount.shared.isSignedIn {
            return (ResponsesLanguageModel(name: name, credential: .chatGPTPlan), name, true)
        }
        guard let apiKey else {
            throw .RuntimeError("No OpenAI API key was given, and no ChatGPT account is signed in.")
        }
        guard let key = apiKey.value, !key.isEmpty else {
            throw .RuntimeError("No API key is stored under '\(apiKey.name)'.")
        }
        return (ResponsesLanguageModel(name: name, apiKey: key), name, true)
    }

    package func fallback(
        after error: any Error,
        on model: any FoundationModels.LanguageModel
    ) -> (model: any FoundationModels.LanguageModel, name: String)? {
        nil
    }
}

extension Agents.LanguageModel {
    /// A ChatGPT model, for Swift, such as `"gpt-6.1-sol"`.
    public static func chatgpt(_ name: String, apiKey: Secret?) -> Agents.LanguageModel {
        Agents.LanguageModel(provider: ChatGPTLanguageModel(name: name, apiKey: apiKey))
    }

    /// Whether OpenAI refused the API key a request was sent with.
    public static func chatGPTRejectsKey(_ error: any Error) -> Bool {
        if case .unauthorized = error as? ResponsesLanguageModel.RequestError { true } else { false }
    }
}
