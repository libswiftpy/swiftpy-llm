import SwiftPy

public enum LLM {
    @MainActor
    public static func initialize() {
        PyBind.module("llm") { module in
            module.classes(
                LanguageModelSession.self,
            )

            if #available(anyAppleOS 27, *) {
                module.classes(
                    LanguageModel.self
                )
            }
        }
    }
}
