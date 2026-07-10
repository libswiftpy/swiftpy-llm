//
//  Tool.swift
//  swiftpy-llm
//
//  Created by Tibor Felföldy on 2026. 07. 05..
//

import SwiftPy
import FoundationModels

@Scriptable
@MainActor
public final class Tool: FoundationModels.Tool, Sendable {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    let makeParams: PyObject
    let function: PyObject
    
    init(argsType: PyObject, function: PyObject) throws {
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
    }
}

extension Tool {
    public func call(arguments: GeneratedContent) async throws -> String {
        let params: PyObject = try makeParams(arguments.jsonString)
        let result: PyObject = try function(params)
        if let task = AsyncTask(result) {
            await task.untilCompletes()
            return try String.cast(task.result?.reference)
        }
        return try String.cast(result.reference)
    }
}
