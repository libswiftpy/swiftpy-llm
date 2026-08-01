import SwiftPy

@MainActor
public func initialize() {
    PyBind.module("agents.native") { module in
        module.classes(
            Tool.self,
            Agent.self,
        )
        
#if swift(>=6.4)
        if #available(anyAppleOS 27, *) {
            module.classes(
                LanguageModel.self
            )
        }
#endif
    }
    
    PyBind.module("agents", in: .module)
}
