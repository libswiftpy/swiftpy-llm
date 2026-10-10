//
//  ClaudeLanguageModel.swift
//  swiftpy-llm
//

import SwiftPy
import Agents
import FoundationModels
import ClaudeForFoundationModels

/// A Claude model, reached with an Anthropic API key from the keychain.
@Scriptable(base: .LanguageModel)
@MainActor
public final class ClaudeLanguageModel {
    /// The model's ID, such as `"claude-sonnet-5-5"`.
    public let name: String

    private let apiKey: Secret

    /// A Claude model. Prefer ``claude.sonnet`` and the other functions of ``claude``.
    ///
    /// name: The model's ID, such as "claude-sonnet-5-5".
    /// api_key: The secret holding an Anthropic API key, from ``keychain.secret``.
    public init(name: String, apiKey: Secret) {
        self.name = name
        self.apiKey = apiKey
    }
}

extension ClaudeLanguageModel: CustomStringConvertible {
    public nonisolated var description: String {
        "<ClaudeLanguageModel name=\"\(name)\">"
    }
}

extension ClaudeLanguageModel: ModelProvider {
    package func resolve() throws(PythonError) -> (model: any FoundationModels.LanguageModel, name: String, reasons: Bool) {
        guard let key = apiKey.value, !key.isEmpty else {
            throw .RuntimeError("No API key is stored under '\(apiKey.name)'.")
        }
        let claudeModel = ClaudeModel.named(name)
        let model = ClaudeForFoundationModels.ClaudeLanguageModel(name: claudeModel, auth: .apiKey(key))
        return (model, name, claudeModel.capabilities.adaptiveThinking)
    }

    package func fallback(
        after error: any Error,
        on model: any FoundationModels.LanguageModel
    ) -> (model: any FoundationModels.LanguageModel, name: String)? {
        nil
    }
}

extension ClaudeModel {
    // Every model the package has a constant for, so a known ID gets its exact capabilities.
    private static let known: [ClaudeModel] = [
        .haiku5_5, .sonnet5_5, .opus5_5, .fable5_1, .fable5, .opus5, .sonnet5,
        .opus4_8, .opus4_7, .opus4_6, .sonnet4_6, .haiku4_5,
    ]

    /// The package's constant for `id`; an ID released after the package is
    /// assumed to accept what the newest models do.
    static func named(_ id: String) -> ClaudeModel {
        known.first { $0.id == id } ?? ClaudeModel(id: id, capabilities: sonnet5_5.capabilities)
    }
}
