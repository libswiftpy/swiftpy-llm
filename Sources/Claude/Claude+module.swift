import SwiftPy
import Agents

/// Binds `claude`; call it after `Agents.initialize()`, which binds the base type.
@MainActor
public func initialize() {
    if !LanguageModel.providerTypes.contains(where: { $0 == ClaudeLanguageModel.self }) {
        LanguageModel.providerTypes.append(ClaudeLanguageModel.self)
    }

    PyBind.module("_claude") { module in
        module.classes(ClaudeLanguageModel.self)
        module.KEY_PROMPT = ClaudeLanguageModel.keyPrompt
    }

    PyBind.module("claude", in: .module)
}
