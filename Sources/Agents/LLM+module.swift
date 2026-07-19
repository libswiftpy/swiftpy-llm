import SwiftPy

@MainActor
public func initialize() {
    PyBind.module("agents.native") { module in
        module.classes(
            Tool.self,
            Agent.self,
        )
        
        if #available(anyAppleOS 27, *) {
            module.classes(
                LanguageModel.self
            )
        }
    }
    
    PyBind.module("agents", in: .module)
}
