//
//  AgentsTests.swift
//  swiftpy-llm
//

import Testing
import Foundation
import FoundationModels
import SwiftPy
@testable import Agents

/// What needs no Apple Intelligence: arguments, and the profile a session is
/// built from, run against a mock model.
@MainActor
@Suite(.serialized)
struct AgentsTests {
    init() async {
        Agents.initialize()
        await Interpreter.run("""
        from agents import *

        def _raised(f):
            try:
                f()
            except Exception as e:
                return type(e).__name__
            return None
        """)
    }

    private func evaluate(_ expression: String) -> String? {
        Interpreter.evaluate(expression)
    }

    @Test func picksALocationByEnumOrClassMethod() {
        #expect(evaluate("repr(SystemLanguageModel().location)") == "<SystemModelLocation.AUTOMATIC: 'automatic'>")
        #expect(evaluate("str(SystemLanguageModel(SystemModelLocation.ON_DEVICE).location == SystemLanguageModel.on_device().location)") == "True")
        #expect(evaluate("SystemLanguageModel.private_cloud_compute().location.name") == "PRIVATE_CLOUD_COMPUTE")
        #expect(evaluate("repr(SystemLanguageModel.automatic())") == "<SystemLanguageModel location=SystemModelLocation.AUTOMATIC>")
        #expect(evaluate("_raised(lambda: SystemLanguageModel('on-device'))") == "TypeError")
    }

    @Test func languageModelIsTheAbstractBase() {
        #expect(evaluate("str(isinstance(SystemLanguageModel(), LanguageModel))") == "True")
        #expect(evaluate("_raised(lambda: LanguageModel())") == "TypeError")
    }

    @Test func agentKeepsTheModelItIsGiven() async {
        await Interpreter.run("_model = SystemLanguageModel.on_device()\n_agent = Agent(model=_model)")
        #expect(evaluate("str(_agent.model is _model)") == "True")
        #expect(evaluate("Agent().model.location.name") == "AUTOMATIC")
        #expect(evaluate("str(Agent().model_name)") == "None")
        #expect(evaluate("_raised(lambda: Agent(model=1))") == "TypeError")
    }

    @Test func validatesSkillsAndHistory() {
        #expect(evaluate("_raised(lambda: Skill('a', 'b'))") == "TypeError")
        #expect(evaluate("Skill('a', 'b', prompt='p').prompt") == "p")
        #expect(evaluate("_raised(lambda: History(rolling_window=0))") == "ValueError")
        #expect(evaluate("_raised(lambda: History(summarize_after=0))") == "ValueError")
    }

    @Test func stubsTypeTheModel() throws {
        let json: String? = try py.module("interpreter")?._stubs?()
        let stubs = try JSONDecoder().decode([String: String].self, from: Data(try #require(json).utf8))
        let native = try #require(stubs.first { $0.value.contains("class SystemLanguageModel") }?.value)
        #expect(native.contains("class LanguageModel"), "\(native)")
        #expect(native.contains("class SystemLanguageModel(LanguageModel)"), "\(native)")
        #expect(native.contains("model: LanguageModel | None=None"), "\(native)")
        #expect(native.contains("location: SystemModelLocation"), "\(native)")
    }

    // MARK: - Profile

    /// The transcripts the model saw over `prompts`.
    private func transcripts(of agent: Agent, prompts: [String]) async throws -> [Transcript] {
        let recorder = TranscriptRecorder()
        let session = LanguageModelSession(profile: agent.profile(for: MockModel(text: "OK", recorder: recorder)))
        for prompt in prompts {
            _ = try await session.respond(to: prompt)
        }
        return recorder.transcripts
    }

    private func isInstructions(_ entry: Transcript.Entry?) -> Bool {
        if case .instructions = entry { true } else { false }
    }

    @Test func sendsTheInstructionsAndEveryEntry() async throws {
        let agent = Agent(instructions: "Be brief.")
        let seen = try await transcripts(of: agent, prompts: ["one", "two"])
        #expect(isInstructions(seen.last?.first))
        #expect(seen.last.map { Array($0).count } == 4)
    }

    @Test func rollingWindowKeepsTheInstructions() async throws {
        let agent = Agent(instructions: "Be brief.", history: try History(rollingWindow: 2))
        let seen = try await transcripts(of: agent, prompts: ["one", "two", "three"])
        let last = try #require(seen.last.map(Array.init))
        #expect(isInstructions(last.first))
        #expect(last.count == 3, "\(last)")
    }

    @Test func summarizingKeepsTheInstructions() async throws {
        let agent = Agent(instructions: "Be brief.", history: try History(summarizeAfter: 2))
        let seen = try await transcripts(of: agent, prompts: ["one", "two", "three"])
        #expect(isInstructions(seen.last?.first), "\(String(describing: seen.last))")
    }
}
