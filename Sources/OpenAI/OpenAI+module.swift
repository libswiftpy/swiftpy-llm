import SwiftPy
import Agents

/// Binds `chatgpt`; call it after `Agents.initialize()`, which binds the base type.
///
/// signInWithChatGPT: Whether `chatgpt.sign_in()` is offered, and a signed-in plan used.
@MainActor
public func initialize(signInWithChatGPT: Bool = false) {
    if !LanguageModel.providerTypes.contains(where: { $0 == ChatGPTLanguageModel.self }) {
        LanguageModel.providerTypes.append(ChatGPTLanguageModel.self)
    }
    ChatGPTAccount.shared.isEnabled = signInWithChatGPT

    PyBind.module("_chatgpt") { module in
        module.classes(ChatGPTLanguageModel.self)
        module.KEY_PROMPT = ChatGPTLanguageModel.keyPrompt
        if signInWithChatGPT { bindSignIn(module) }
    }

    PyBind.module("chatgpt", in: .module)
}

@MainActor
private func bindSignIn(_ module: PyModule) {
    module.def(
        "sign_in() -> str",
        docstring: """
        Signs in with a ChatGPT account, whose plan the models then use instead \
        of an API key. Returns the account's email.

        The sign-in opens in the browser; the first time, it asks to let this \
        app use your ChatGPT plan. Its tokens stay in this device's keychain.

        ```python
        import chatgpt
        from agents import Agent

        chatgpt.sign_in()
        agent = Agent(model=chatgpt.sol())
        ```
        """
    ) { argc, argv in
        PyBind.blocking(argc, argv) {
            try await ChatGPTAccount.shared.signIn()
        }
    }

    module.def(
        "sign_out() -> None",
        docstring: """
        Signs out of ChatGPT, after which the models ask for an API key again.
        """
    ) { argc, argv in
        PyBind.blocking(argc, argv) {
            await ChatGPTAccount.shared.signOut()
        }
    }

    module.def(
        "account() -> str | None",
        docstring: """
        The signed-in ChatGPT account's email, or None when signed out.
        """
    ) { argc, argv in
        PyBind.function(argc, argv) {
            ChatGPTAccount.shared.email
        }
    }
}
