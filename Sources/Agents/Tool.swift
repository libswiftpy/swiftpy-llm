//
//  Tool.swift
//  swiftpy-llm
//
//  Created by Tibor Felföldy on 2026. 07. 05..
//

import SwiftPy
import SwiftPyViews
import FoundationModels
import SwiftUI

/// A function an ``agents.Agent`` can call, built by the ``agents.tool`` decorator.
@Scriptable
@MainActor
public final class Tool: @preconcurrency FoundationModels.Tool, Sendable {
    /// The name the model calls the tool by, taken from the function's name.
    public let name: String

    /// What the tool does, taken from the function's docstring. This is what the model reads to decide when to call it.
    public let description: String

    /// The schema of the arguments the model fills in before each call.
    public let parameters: GenerationSchema

    internal let makeParams: PyObject
    internal let function: PyObject
    internal let base: PyObject
    private var formatInput: PyObject?
    private var formatOutput: PyObject?

    /// Creates a tool. Prefer ``agents.tool``, which builds this from a function.
    ///
    /// args_type: A class carrying the parameter schema, either a ``modeling.model`` class or one synthesized from the function's annotations.
    /// function: The callable the tool invokes, taking a single arguments object, and optionally the function to call with them in place of its own.
    /// base: The undecorated function, which calling the tool forwards to.
    public init(argsType: PyObject, function: PyObject, base: PyObject) throws {
        guard let schema: [String: Any] = argsType._schema,
              let makeParams = argsType._from_json else {
            throw PythonError.ValueError("Failed to get tool parameters")
        }

        let name: String = argsType._tool_name ?? function.__name__ ?? "tool"
        let description: String = argsType._tool_description ?? function.__doc__ ?? ""

        // First, so the model titles the call before writing its arguments.
        var withTitle = schema
        if var properties = schema["properties"] as? [[String: Any]] {
            properties.insert([
                "name": Self.titleKey,
                "type": "str",
                "description": "A few words on what this call does, shown to the user, like 'Try a GET request'.",
            ], at: 0)
            withTitle["properties"] = properties
        }

        self.name = name
        self.description = description
        self.parameters = try GenerationSchema(pythonModelSchema: withTitle)
        self.makeParams = makeParams
        self.function = function
        self.base = base
    }

    /// Runs the underlying function, so a tool stays callable without a model.
    ///
    /// params: The arguments the undecorated function takes. Await the result.
    func __call__(params: Unpack) async throws -> PyObject? {
        try await awaited(invoke(base, arguments: params.values))
    }

    /// Sets what an expanded call shows of its input, in place of each argument as `name: value`.
    ///
    /// fn: Takes the same arguments as the tool, and returns a view, or a string shown as Markdown.
    ///
    /// ````python
    /// @tool
    /// def run(code: str) -> str:
    ///     '''Runs Python code.'''
    ///     ...
    ///
    /// @run.input
    /// def run_input(code: str) -> str:
    ///     return f"```python\n{code}\n```"
    /// ````
    func input(_ fn: PyObject) -> PyObject {
        formatInput = fn
        return fn
    }

    /// Sets what an expanded call shows of its result, in place of a plain code block.
    ///
    /// fn: Takes what the tool returned, and returns a view, or a string shown as Markdown.
    ///
    /// ```python
    /// @tool
    /// def docs(name: str) -> str:
    ///     '''Looks up the documentation of a name.'''
    ///     ...
    ///
    /// @docs.output
    /// def docs_output(markdown: str) -> str:
    ///     return markdown
    /// ```
    func output(_ fn: PyObject) -> PyObject {
        formatOutput = fn
        return fn
    }
}

extension Tool {
    /// The argument the model titles a call's log with. Hyphenated, so no
    /// Python parameter can take the name.
    static let titleKey = "call-title"

    /// The title, and the arguments the function takes without it.
    static func splitTitle(from arguments: GeneratedContent) -> (title: String?, arguments: GeneratedContent) {
        guard case .structure(var properties, let orderedKeys) = arguments.kind,
              let title = properties.removeValue(forKey: titleKey) else {
            return (nil, arguments)
        }
        let rest = GeneratedContent(kind: .structure(
            properties: properties,
            orderedKeys: orderedKeys.filter { $0 != titleKey }
        ))
        return (try? title.value(String.self), rest)
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        let (title, arguments) = Self.splitTitle(from: arguments)
        let params: PyObject = try makeParams(arguments.jsonString)

        // Shown while it runs, and filled in once it's done.
        let log = ToolCallLog()
        display(log, title: title, input: await inputView(of: arguments, params: params))
        defer { log.isRunning = false }

        do {
            let result = try await awaited(invoke(function, arguments: [params]))

            // The model reads text, so a number or a list is fine to return: it
            // goes through str(), the way print would show it.
            let text = try result.map { (object) -> String in
                try py.module("builtins")!.throwing.str(object)
            } ?? "None"
            log.output = await outputView(of: result, text: text)
            return text
        } catch let error as PythonError where error.type != "KeyboardInterrupt" {
            // Handed back as the result, so the model can see what went wrong
            // and try again, rather than its whole response failing.
            let text = Self.failureText(of: error)
            log.failure = text
            return text
        } catch {
            log.failure = Self.failureText(of: error)
            throw error
        }
    }

    /// What `result` comes to: awaited, when it's a coroutine or a task.
    private func awaited(_ result: PyObject) async throws -> PyObject? {
        guard AsyncTask(result) != nil || PyRuntime.isCoroutine(result) else { return result }
        return try await AsyncTask.from(result).untilCompletes()
    }

    /// `text` in a plain code block, so it keeps its lines. The fence is longer
    /// than any run of backticks inside.
    static func codeBlock(_ text: String) -> String {
        let longest = text.matches(of: /`+/).map(\.output.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text.trimmingCharacters(in: .newlines))\n\(fence)"
    }

    /// What a tool raised as `agents` formats it, or else the traceback
    /// without the colours CPython adds.
    static func failureText(of error: any Error) -> String {
        if let error = error as? PythonError, error.type == "_ToolFailure" {
            return error.value
        }
        return String(describing: error).replacing(/\u{1B}\[[0-9;]*m/, with: "")
    }

    // On the Python thread, as a cell runs, so a blocking call like
    // requests.get can wait there; main can't.
    @PythonActor
    private func invoke(_ function: PyObject, arguments: [PyObject]) throws -> PyObject {
        try PyRuntime.call(function, arguments: arguments)
    }

    /// The input as `input` formatted it, or each argument as it came.
    private func inputView(of arguments: GeneratedContent, params: PyObject) async -> AnyView {
        let plain = AnyView(ToolArguments(arguments: arguments))
        guard let formatInput else { return plain }
        do {
            return try Self.formatted(await invoke(function, arguments: [params, formatInput]), by: "input")
        } catch {
            return Self.fallback(plain, failure: error)
        }
    }

    /// The result as `output` formatted it, or its text in a code block.
    private func outputView(of result: PyObject?, text: String) async -> AnyView {
        let plain = AnyView(MarkdownContent(model: Markdown(text: Self.codeBlock(text))))
        guard let formatOutput else { return plain }
        do {
            return try Self.formatted(await invoke(formatOutput, arguments: [result ?? .none]), by: "output")
        } catch {
            return Self.fallback(plain, failure: error)
        }
    }

    /// What a formatter returned: a string as Markdown, or a view.
    private static func formatted(_ object: PyObject, by name: String) throws -> AnyView {
        if let text = String(object) {
            return AnyView(MarkdownContent(model: Markdown(text: text)))
        }
        if let view = object.reference.view {
            return view
        }
        throw PythonError.TypeError("\(name)() returned \(object.typeName), not a view or a string")
    }

    // Only the log falls back; the call goes ahead.
    private static func fallback(_ plain: AnyView, failure: any Error) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 4) {
            plain
            Text(failureText(of: failure))
                .font(.caption)
                .foregroundStyle(.red)
        })
    }

    private func display(_ log: ToolCallLog, title: String?, input: AnyView) {
        let title = title?.replacing("\n", with: " ") ?? ""
        let view = ToolCallView(log: log, title: title.isEmpty ? name : title, input: input)
        Interpreter.interface.display(AnyView(view))
    }
}

/// A call's state, as its log shows it.
@MainActor
@Observable
private final class ToolCallLog {
    var isRunning = true
    var output: AnyView?
    var failure: String?
}

private struct ToolCallView: View {
    let log: ToolCallLog
    let title: String
    let input: AnyView

    var body: some View {
        DisclosureLogContainerView(tint: .orange, isInProgress: log.isRunning) {
            input

            if let output = log.output {
                output
                    .environment(\.trimsLeadingHeadingPadding, true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let failure = log.failure {
                Text(failure)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } label: {
            Label(title, systemImage: "wrench.and.screwdriver")
                .font(.body.bold())
                .lineLimit(1)
        }
    }
}

/// Each argument as `name: value`; a string in full, lines and all.
private struct ToolArguments: View {
    let arguments: GeneratedContent

    var body: some View {
        if case let .structure(properties, orderedKeys) = arguments.kind, !orderedKeys.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(orderedKeys, id: \.self) { key in
                    if let value = properties[key] {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(key):").bold()
                            Text((try? value.value(String.self)) ?? value.jsonString)
                        }
                    }
                }
            }
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}
