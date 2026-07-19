//
//  Tool.swift
//  swiftpy-llm
//
//  Created by Tibor Felföldy on 2026. 07. 05..
//

import SwiftPy
import FoundationModels
import SwiftUI

/// A tool what can be called by an llm.Agent.
@Scriptable
@MainActor
public final class Tool: FoundationModels.Tool, Sendable {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    internal let makeParams: PyObject
    internal let function: PyObject
    internal let base: PyObject
    
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

    func __call__(params: Unpack) async throws -> PyObject {
        try py.retain(py.call(base.reference, unpacking: params.values))
    }
}

extension Tool {
    public func call(arguments: GeneratedContent) async throws -> String {
        let params: PyObject = try makeParams(arguments.jsonString)
       
        let result: PyObject = try function(params)
        if let task = AsyncTask(result) {
            await task.untilCompletes()
            let result = try String.cast(task.result?.reference)
            log(arguments: arguments, result: result)
            return result
        }
        
        let resultString = try String.cast(result.reference)
        log(arguments: arguments, result: resultString)
        return resultString
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
        let view = LogContainerView(tint: .orange, title: "\(self.name)(\(paramStr))", icon: "wrench.and.screwdriver") {
            if let result {
                Text(result)
                    .font(.caption.monospaced())
            }
        }
        Interpreter.onDisplay(AnyView(view))
    }
}
