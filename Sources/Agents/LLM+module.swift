import SwiftPy

@MainActor
public func initialize() {
    PyBind.module("agents.native") { module in
        let base = PyType.LanguageModel.object
        module.LanguageModel = base
        base.__module__ = module.__name__

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
