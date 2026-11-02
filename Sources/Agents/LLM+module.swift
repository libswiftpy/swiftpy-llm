import SwiftPy

@MainActor
public func initialize() {
    PyBind.module("_agents") { module in
        let base = PyType.LanguageModel.object
        module.LanguageModel = base
        // As `classes` homes the others; `agents` then moves them all to itself.
        if base.__module__ as String? == "builtins" {
            base.__module__ = module.__name__
        }

        module.classes(
            Tool.self,
            Agent.self,
            SystemLanguageModel.self,
            Skill.self,
            History.self,
        )
    }

    PyBind.module("agents", in: .module)
}
