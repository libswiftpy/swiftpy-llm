import SwiftPy

public enum LLM {
    @MainActor
    public static func initialize() {
        PyBind.module("llm.native") { module in
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

        PyBind.module("llm", in: .module)
    }
}
