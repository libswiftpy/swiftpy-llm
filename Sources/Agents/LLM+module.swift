import SwiftPy

@MainActor
public func initialize() {
    PyBind.module("agents.native") { module in
        module.classes(
            Tool.self,
            Agent.self,
        )
    }
    
    PyBind.module("agents", in: .module)
}
