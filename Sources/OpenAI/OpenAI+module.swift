import SwiftPy
import Agents

/// Binds `chatgpt`; call it after `Agents.initialize()`, which binds the base type.
@MainActor
public func initialize() {
    if !LanguageModel.providerTypes.contains(where: { $0 == ChatGPTLanguageModel.self }) {
        LanguageModel.providerTypes.append(ChatGPTLanguageModel.self)
    }

    PyBind.module("_chatgpt") { module in
        module.classes(ChatGPTLanguageModel.self)
        module.KEY_PROMPT = ChatGPTLanguageModel.keyPrompt
    }

    PyBind.module("chatgpt", in: .module)
}
