//
//  ClaudeTests.swift
//  swiftpy-llm
//

import Testing
import Foundation
@testable import SwiftPy
import Agents
@testable import Claude
import ClaudeForFoundationModels

/// The synchronizable keychain needs an entitlement the test binary can't carry.
@MainActor
final class InMemorySecretStorage: SecretStorage {
    var values: [String: String] = [:]

    func value(for key: String) -> String? { values[key] }

    func set(_ value: String, for key: String) throws(PythonError) {
        values[key] = value
    }

    func remove(_ key: String) throws(PythonError) {
        values[key] = nil
    }

    func names() -> [String] {
        values.keys.sorted()
    }
}

/// Everything short of a request, which needs a real API key.
@MainActor
@Suite(.serialized)
struct ClaudeTests {
    private let storage = InMemorySecretStorage()

    init() async {
        storage.values["ANTHROPIC_API_KEY"] = "test-key"
        Keychain.storage = storage
        Agents.initialize()
        Claude.initialize()
        await Interpreter.run("""
        import claude
        from agents import *
        _sonnet = claude.sonnet()
        """)
    }

    private func evaluate(_ expression: String) -> String? {
        Interpreter.evaluate(expression)
    }

    @Test func familiesAreTheLatestModels() async {
        await Interpreter.run("""
        _names = [m().name for m in (claude.haiku, claude.sonnet, claude.opus, claude.fable)]
        """)
        let latest = [ClaudeModel.haiku5_5, .sonnet5_5, .opus5_5, .fable5_1].map(\.id)
        #expect(evaluate("','.join(_names)") == latest.joined(separator: ","))
    }

    @Test func isALanguageModel() async {
        #expect(evaluate("str(isinstance(_sonnet, LanguageModel))") == "True")
        #expect(evaluate("claude.ClaudeLanguageModel.__module__") == "claude")
        #expect(evaluate("repr(_sonnet)") == "<ClaudeLanguageModel name=\"claude-sonnet-5-5\">")

        await Interpreter.run("_agent = Agent(model=claude.model('claude-opus-4-8'))")
        #expect(evaluate("_agent.model.name") == "claude-opus-4-8")
    }

    @Test func looksUpTheModelsCapabilities() {
        #expect(ClaudeModel.named("claude-opus-4-6") == .opus4_6)
        #expect(ClaudeModel.named("claude-opus-4-6").capabilities.samplingParams)

        let unknown = ClaudeModel.named("claude-sonnet-9")
        #expect(unknown.id == "claude-sonnet-9")
        #expect(unknown.capabilities == ClaudeModel.sonnet5_5.capabilities)
    }

    @Test func resolvesWithTheStoredKey() throws {
        let sonnet = ClaudeLanguageModel(name: "claude-sonnet-5-5", apiKey: Secret(name: "ANTHROPIC_API_KEY"))
        let resolved = try sonnet.resolve()
        #expect(resolved.name == "claude-sonnet-5-5")
        #expect(resolved.reasons)

        let haiku = ClaudeLanguageModel(name: "claude-haiku-4-5", apiKey: Secret(name: "ANTHROPIC_API_KEY"))
        #expect(try !haiku.resolve().reasons)

        let missing = ClaudeLanguageModel(name: "claude-sonnet-5-5", apiKey: Secret(name: "MISSING_KEY"))
        #expect(throws: PythonError.self) { try missing.resolve() }
    }

    @Test func stubsTypeTheModel() throws {
        let json: String? = try py.module("interpreter")?._stubs?()
        let stubs = try JSONDecoder().decode([String: String].self, from: Data(try #require(json).utf8))
        let native = try #require(stubs.first { $0.value.contains("class ClaudeLanguageModel") }?.value)
        #expect(native.contains("class ClaudeLanguageModel(LanguageModel)"), "\(native)")
        #expect(native.contains("api_key: Secret"), "\(native)")
    }
}
