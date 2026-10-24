//
//  ChatGPTTests.swift
//  swiftpy-llm
//

import Testing
import Foundation
@testable import SwiftPy
import Agents
@testable import OpenAI

/// The suites share `ChatGPTAccount.shared` and the mock servers, so they run one at a time.
@Suite(.serialized)
enum OpenAISuite {}

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

extension OpenAISuite {
    @MainActor
    @Suite(.serialized)
    struct ChatGPTTests {
        private let storage = InMemorySecretStorage()

        init() async {
            storage.values["OPENAI_API_KEY"] = "test-key"
            Keychain.storage = storage
            Agents.initialize()
            OpenAI.initialize()
            await Interpreter.run("""
            import chatgpt
            from agents import *
            _sol = chatgpt.sol()
            """)
        }

        private func evaluate(_ expression: String) -> String? {
            Interpreter.evaluate(expression)
        }

        @Test func functionsAreTheFlagshipModels() async {
            await Interpreter.run("_names = [m().name for m in (chatgpt.astra, chatgpt.sol, chatgpt.luna)]")
            #expect(evaluate("','.join(_names)") == "gpt-6-astra,gpt-6.1-sol,gpt-6-luna")
        }

        @Test func isALanguageModel() async {
            #expect(evaluate("str(isinstance(_sol, LanguageModel))") == "True")
            #expect(evaluate("chatgpt.ChatGPTLanguageModel.__module__") == "chatgpt")
            #expect(evaluate("repr(_sol)") == "<ChatGPTLanguageModel name=\"gpt-6.1-sol\">")

            await Interpreter.run("_agent = Agent(model=chatgpt.model('gpt-6-sol'))")
            #expect(evaluate("_agent.model.name") == "gpt-6-sol")
        }

        @Test func signingInIsntOfferedWithoutTheFlag() {
            #expect(evaluate("str(hasattr(chatgpt, 'sign_in'))") == "False")
            #expect(evaluate("str('sign_in' in chatgpt.__all__)") == "False")
        }

        @Test func resolvesWithTheStoredKey() throws {
            let sol = ChatGPTLanguageModel(name: "gpt-6.1-sol", apiKey: Secret(name: "OPENAI_API_KEY"))
            let resolved = try sol.resolve()
            #expect(resolved.name == "gpt-6.1-sol")
            #expect(resolved.reasons)
            #expect((resolved.model as? ResponsesLanguageModel)?.credential == .apiKey("test-key"))

            let missing = ChatGPTLanguageModel(name: "gpt-6.1-sol", apiKey: Secret(name: "MISSING_KEY"))
            #expect(throws: PythonError.self) { try missing.resolve() }
        }

        @Test func asksForAMissingKeyWithWhereToGetOne() async {
            storage.values["OPENAI_API_KEY"] = nil
            var asked: SecretRequest?
            Interpreter.interface.requestSecret = { request in
                asked = request
                return "entered-key"
            }
            defer { Interpreter.interface.requestSecret = InterpreterInterface().requestSecret }

            await Interpreter.run("_asked = chatgpt.model('any')")

            #expect(asked == SecretRequest(name: "OPENAI_API_KEY", prompt: ChatGPTLanguageModel.keyPrompt))
            #expect(storage.values["OPENAI_API_KEY"] == "entered-key")
        }
    }
}
