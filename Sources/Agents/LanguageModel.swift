//
//  LanguageModel.swift
//  swiftpy-llm
//

import SwiftPy
import FoundationModels

@MainActor
extension PyType {
    /// The base of the models an ``agents.Agent`` runs on; only its subclasses
    /// are made.
    static let LanguageModel: PyType = .make("LanguageModel") { type in
        type.function("__new__(cls, *args, **kwargs)") { _, _ in
            PyAPI.return {
                throw PythonError.TypeError("LanguageModel can't be instantiated; use SystemLanguageModel")
            }
        }
    }
}

/// What a model gives an agent: FoundationModels' own, which the agent builds
/// its sessions from.
@MainActor
protocol ModelProvider: PythonBindable {
    /// The model for a new session, its name, and whether it takes a reasoning level.
    func resolve() throws(PythonError) -> (model: any FoundationModels.LanguageModel, name: String, reasons: Bool)

    /// Where a request that failed on `model` continues, or `nil` to raise the error.
    func fallback(
        after error: any Error,
        on model: any FoundationModels.LanguageModel
    ) -> (model: any FoundationModels.LanguageModel, name: String)?
}

/// Any `agents.LanguageModel`, as Swift takes it: a struct rather than a
/// shared base class, which two `@Scriptable` classes can't have.
@MainActor
public struct LanguageModel {
    let provider: any ModelProvider
}

extension LanguageModel: PythonConvertible {
    public static var pyType: PyType { .LanguageModel }

    public static func isConvertible(_ reference: PyRef) -> Bool {
        SystemLanguageModel.isConvertible(reference)
    }

    public static func fromPython(_ reference: PyRef) -> LanguageModel {
        LanguageModel(provider: SystemLanguageModel.fromPython(reference))
    }

    public func toPython() throws(PythonError) -> PyObject {
        try provider.toPython()
    }
}
