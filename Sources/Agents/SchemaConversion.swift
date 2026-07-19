//
//  SchemaConversion.swift
//  swiftpy-llm
//
//  Created by Tibor Felföldy on 2026. 07. 04..
//

import Foundation
import FoundationModels
import SwiftPy

public struct PythonModelSchemaConverter {
    public init() {}
    
    public func generationSchema(from schema: [String: Any]) throws(PythonError) -> GenerationSchema {
        let root = try dynamicGenerationSchema(from: schema)
        do {
            return try GenerationSchema(root: root, dependencies: [])
        } catch {
            throw .ValueError(String(describing: error))
        }
    }

    public func dynamicGenerationSchema(from schema: [String: Any]) throws(PythonError) -> DynamicGenerationSchema {
        guard let name = schema["name"] as? String else {
            throw .KeyError("Missing name")
        }

        guard let rawProperties = schema["properties"] as? [[String: Any]] else {
            throw .KeyError("Missing properties")
        }

        let properties = try rawProperties.enumerated().map { index, property throws(PythonError) in
            try dynamicProperty(from: property, index: index)
        }

        return DynamicGenerationSchema(
            name: name,
            properties: properties
        )
    }

    private func dynamicProperty(
        from property: [String: Any],
        index: Int
    ) throws(PythonError) -> DynamicGenerationSchema.Property {
        guard let name = property["name"] as? String else {
            throw .KeyError("Missing name in property at index \(index)")
        }

        guard let type = property["type"] as? String else {
            throw .KeyError("Missing type in property at index \(index)")
        }

        let schema = try dynamicGenerationSchema(forPythonType: type)

        return DynamicGenerationSchema.Property(
            name: name,
            schema: schema
        )
    }

    private func dynamicGenerationSchema(forPythonType type: String) throws(PythonError) -> DynamicGenerationSchema {
        let nonNilTypes = splitUnion(type).filter { $0 != "None" }

        guard let baseType = nonNilTypes.first else {
            throw .ValueError("Unsupported schema type: \(type)")
        }

        switch baseType {
        case "str", "String":
            return DynamicGenerationSchema(type: String.self)
        case "int", "Int":
            return DynamicGenerationSchema(type: Int.self)
        case "float", "Double":
            return DynamicGenerationSchema(type: Double.self)
        case "bool", "Bool":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            throw .ValueError("Unsupported schema type: \(type)")
        }
    }

    private func splitUnion(_ type: String) -> [String] {
        type
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension GenerationSchema {
    public init(pythonModelSchema schema: [String: Any]) throws(PythonError) {
        self = try PythonModelSchemaConverter().generationSchema(from: schema)
    }
}
