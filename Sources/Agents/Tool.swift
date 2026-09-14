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

    /// Creates a tool. Prefer ``agents.tool``, which builds this from a function.
    ///
    /// args_type: A class carrying the parameter schema, either a ``modeling.model`` class or one synthesized from the function's annotations.
    /// function: The callable the tool invokes, taking a single arguments object.
    /// base: The undecorated function, which calling the tool forwards to.
    public init(argsType: PyObject, function: PyObject, base: PyObject) throws {
        guard let schema: [String: Any] = argsType._schema,
              let makeParams = argsType._from_json else {
            throw PythonError.ValueError("Failed to get tool parameters")
        }

        let name: String = argsType._tool_name ?? function.__name__ ?? "tool"
        let description: String = argsType._tool_description ?? function.__doc__ ?? ""

        self.name = name
        self.description = description
        self.parameters = try GenerationSchema(pythonModelSchema: schema)
        self.makeParams = makeParams
        self.function = function
        self.base = base
    }

    /// Runs the underlying function, so a tool stays callable without a model.
    ///
    /// params: The arguments the undecorated function takes. Await the result.
    func __call__(params: Unpack) async throws -> PyObject? {
        let result = try py.retain(py.call(base.reference, unpacking: params.values))
        guard let task = AsyncTask(result) else { return result }

        try await task.untilCompletes()
        return task.result
    }
}

extension Tool {
    public func call(arguments: GeneratedContent) async throws -> String {
        let params: PyObject = try makeParams(arguments.jsonString)

        var result: PyObject? = try function(params)
        if let task = AsyncTask(result) {
            try await task.untilCompletes()
            result = task.result
        }

        // The model reads text, so a number or a list is fine to return: it
        // goes through str(), the way print would show it.
        let text = try result.map { (object) -> String in
            try py.module("builtins")!.throwing.str(object)
        } ?? "None"
        log(arguments: arguments, result: text)
        return text
    }

    private func log(arguments: GeneratedContent, result: String?) {
        let paramStr: String = {
            guard let data = arguments.jsonString.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return arguments.jsonString
            }
            return dict.map { key, value in
                let valueStr = value is String ? "\"\(value)\"" : "\(value)"
                return "\(key)=\(valueStr)"
            }.joined(separator: ", ")
        }()
        let view = DisclosureLogContainerView(tint: .orange) {
            if let result {
                MarkdownContent(model: Markdown(text: result))
                    .environment(\.trimsLeadingHeadingPadding, true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } label: {
            Label("\(self.name)(\(paramStr))", systemImage: "wrench.and.screwdriver")
                .font(.body.monospaced().bold())
                .lineLimit(1)
        }
        Interpreter.interface.display(AnyView(view))
    }
}
