__doc__ = """ChatGPT models for ``agents.Agent``, through OpenAI's Responses API.

Each function returns a model to pass as an agent's `model`. They need an
OpenAI API key, kept in the keychain under `OPENAI_API_KEY`: the first call
asks for it, with a link to platform.openai.com, and its value never reaches
Python.

```python
import chatgpt
from agents import Agent

agent = Agent(model=chatgpt.sol())
answer = await agent.respond("Name a pasta dish")
```"""
__all__ = ["ChatGPTLanguageModel", "astra", "luna", "model", "sol"]

import _chatgpt
import keychain
from _chatgpt import KEY_PROMPT as _KEY_PROMPT, ChatGPTLanguageModel

ChatGPTLanguageModel.__module__ = __name__

from _chatgpt import account, sign_out

__all__ += ["account", "sign_out"]

# Bound only where signing in is offered.
if hasattr(_chatgpt, "sign_in"):
    from _chatgpt import sign_in

    __all__ += ["sign_in"]


def _signed_in() -> bool:
    return account() is not None


def model(name: str) -> ChatGPTLanguageModel:
    """A ChatGPT model by its ID.

    name: The model's ID, such as "gpt-6-sol".
    """
    if _signed_in():
        return ChatGPTLanguageModel(name)
    return ChatGPTLanguageModel(name, keychain.secret("OPENAI_API_KEY", prompt=_KEY_PROMPT))


def astra() -> ChatGPTLanguageModel:
    """GPT-6 Astra: the most capable, for the most demanding work."""
    return model("gpt-6-astra")


def sol() -> ChatGPTLanguageModel:
    """GPT-6.1 Sol: near Astra for complex work, at a lower cost."""
    return model("gpt-6.1-sol")


def luna() -> ChatGPTLanguageModel:
    """GPT-6 Luna: the fastest and most cost-effective."""
    return model("gpt-6-luna")
