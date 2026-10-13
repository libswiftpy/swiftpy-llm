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

    @Test func typesReportThePublicModule() async {
        #expect(evaluate("repr(Agent)") == "<class 'agents.Agent'>")
        #expect(evaluate("LanguageModel.__module__") == "agents")
        // Errors raised in C name the type bare, not `builtins.Agent`.
        await Interpreter.run("""
        import copy
        try:
            copy.deepcopy(Agent())
        except TypeError as e:
            _message = str(e)
        """)
        #expect(evaluate("_message") == "cannot pickle 'Agent' object")
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

    // MARK: - Tools

    @Test func toolsAskForACallTitleFirst() async throws {
        await Interpreter.run("""
        @tool
        def _add(a: int, b: int) -> int:
            "Adds two numbers."
            return a + b
        """)
        let tool = try Tool.cast(try #require(py.main._add))
        let schema = String(decoding: try JSONEncoder().encode(tool.parameters), as: UTF8.self)
        #expect(schema.contains("Try a GET request"), "\(schema)")
        #expect(schema.contains(#""x-order":["call-title","a","b"]"#), "\(schema)")

        let arguments = try GeneratedContent(json: #"{"call-title": "Add them", "a": 1, "b": 2}"#)
        #expect(try await tool.call(arguments: arguments) == "3")
    }

    @Test func aTitleParameterIsTheFunctionsOwn() async throws {
        await Interpreter.run("""
        @tool
        def _note(title: str, body: str) -> str:
            "Saves a note."
            return title + ": " + body
        """)
        let tool = try Tool.cast(try #require(py.main._note))
        let arguments = try GeneratedContent(json: #"{"call-title": "Save a note", "title": "Groceries", "body": "milk"}"#)
        #expect(try await tool.call(arguments: arguments) == "Groceries: milk")
    }

    @Test func inputFormatsWithTheToolsArguments() async throws {
        await Interpreter.run("""
        from modeling import model

        _seen = []

        @tool
        def _greet(name: str, times: int) -> str:
            "Greets someone."
            return "hi " * times + name

        @_greet.input
        def _greet_input(name: str, times: int) -> str:
            _seen.append((name, times))
            return f"`{name}` x{times}"

        @model
        class _Query:
            text: str

        @tool
        def _search(query: _Query) -> str:
            "Searches."
            return query.text

        @_search.input
        def _search_input(query: _Query) -> str:
            _seen.append(query.text)
            return query.text

        @tool
        def _fails(x: int) -> int:
            "Fails to format."
            return x

        @_fails.input
        def _fails_input(x: int) -> str:
            raise ValueError("nope")
        """)
        // Returns the function, so its own name stays bound to it.
        #expect(evaluate("str(_greet_input.__name__)") == "_greet_input")

        let greet = try Tool.cast(try #require(py.main._greet))
        #expect(try await greet.call(arguments: GeneratedContent(json: #"{"call-title": "Greet", "name": "Ada", "times": 2}"#)) == "hi hi Ada")

        let search = try Tool.cast(try #require(py.main._search))
        #expect(try await search.call(arguments: GeneratedContent(json: #"{"text": "swift"}"#)) == "swift")
        #expect(evaluate("str(_seen)") == "[('Ada', 2), 'swift']")

        // A formatter that raises leaves the call itself alone.
        let fails = try Tool.cast(try #require(py.main._fails))
        #expect(try await fails.call(arguments: GeneratedContent(json: #"{"x": 7}"#)) == "7")
    }

    @Test func toolTakesItsInputFormatter() async throws {
        await Interpreter.run("""
        _formatted = []

        @tool(input=lambda code: _formatted.append(code) or f"`{code}`")
        def _run(code: str) -> str:
            "Runs code."
            return code.upper()

        @tool()
        def _plain(x: int) -> int:
            "Returns x."
            return x
        """)
        let run = try Tool.cast(try #require(py.main._run))
        #expect(try await run.call(arguments: GeneratedContent(json: #"{"code": "print(1)"}"#)) == "PRINT(1)")
        #expect(evaluate("str(_formatted)") == "['print(1)']")

        let plain = try Tool.cast(try #require(py.main._plain))
        #expect(try await plain.call(arguments: GeneratedContent(json: #"{"x": 3}"#)) == "3")
    }

    @Test func aFailingToolReturnsItsTraceback() async throws {
        await Interpreter.run("""
        @tool
        def _divide(a: int, b: int) -> float:
            "Divides a by b."
            return a / b
        """)
        let divide = try Tool.cast(try #require(py.main._divide))
        let text = try await divide.call(arguments: GeneratedContent(json: #"{"a": 1, "b": 0}"#))
        #expect(text.contains("Traceback"), "\(text)")
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("ZeroDivisionError: division by zero"), "\(text)")
        #expect(!text.contains("\u{1B}["), "\(text)")
        // The error is in the tool's own body, so its frame stays.
        #expect(text.contains("in _divide"), "\(text)")
        #expect(!text.contains("wrapped") && !text.contains("_call"), "\(text)")
    }

    @Test func aToolsOwnFrameGoesWhenWhatItRanFailed() async throws {
        await Interpreter.run("""
        @tool
        async def _exec(code: str) -> str:
            "Runs code."
            exec(code, {})
            return "ok"
        """)
        let tool = try Tool.cast(try #require(py.main._exec))
        let text = try await tool.call(arguments: GeneratedContent(json: #"{"code": "import no_such_module"}"#))
        #expect(text.contains("File \"<string>\", line 1"), "\(text)")
        #expect(text.contains("ModuleNotFoundError"), "\(text)")
        #expect(!text.contains("in _exec") && !text.contains("_awaited"), "\(text)")

        let invalid = try await tool.call(arguments: GeneratedContent(json: #"{"code": "x = (1"}"#))
        #expect(invalid.contains("SyntaxError"), "\(invalid)")
        #expect(!invalid.contains("in _exec"), "\(invalid)")
    }

    @Test func aToolKeepsItsFrameWhenWhatItCalledFailed() async throws {
        await Interpreter.run("""
        def _lookup(name):
            raise KeyError(name)

        @tool
        def _docs(name: str) -> str:
            "Looks up docs."
            return _lookup(name)
        """)
        let tool = try Tool.cast(try #require(py.main._docs))
        let text = try await tool.call(arguments: GeneratedContent(json: #"{"name": "nope"}"#))
        #expect(text.contains("in _docs") && text.contains("in _lookup"), "\(text)")
        #expect(text.contains("KeyError: 'nope'"), "\(text)")
    }

    @Test func outputFormatsWhatTheToolReturned() async throws {
        await Interpreter.run("""
        _outputs = []

        @tool(output=lambda result: _outputs.append(result) or "**done**")
        def _stats(n: int) -> dict:
            "Counts to n."
            return {"n": n}

        @tool
        def _docs(name: str) -> str:
            "Looks up docs."
            return f"# {name}"

        @_docs.output
        def _docs_output(markdown: str) -> str:
            _outputs.append(markdown)
            raise ValueError("nope")
        """)
        let stats = try Tool.cast(try #require(py.main._stats))
        // The model still reads str() of the result.
        #expect(try await stats.call(arguments: GeneratedContent(json: #"{"n": 2}"#)) == "{'n': 2}")

        // A formatter that raises leaves the result alone.
        let docs = try Tool.cast(try #require(py.main._docs))
        #expect(try await docs.call(arguments: GeneratedContent(json: #"{"name": "views"}"#)) == "# views")

        // Formatters get the returned object itself, not its text.
        #expect(evaluate("str(_outputs)") == "[{'n': 2}, '# views']")
    }

    @Test func resultsShowInAPlainCodeBlock() {
        #expect(Tool.codeBlock("a\nb\n") == "```\na\nb\n```")
        #expect(Tool.codeBlock("x ```py y") == "````\nx ```py y\n````")
    }

    @Test func splitsTheTitleFromTheArguments() throws {
        let (title, rest) = Tool.splitTitle(from: try GeneratedContent(json: #"{"call-title": "Add them", "a": 1}"#))
        #expect(title == "Add them")
        #expect(try rest.value(Int.self, forProperty: "a") == 1)
        #expect(!rest.jsonString.contains("call-title"))

        let (none, same) = Tool.splitTitle(from: try GeneratedContent(json: #"{"a": 1}"#))
        #expect(none == nil)
        #expect(try same.value(Int.self, forProperty: "a") == 1)
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
