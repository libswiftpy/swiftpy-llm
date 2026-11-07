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
__all__ = ["ChatGPTLanguageModel", "astra", "image", "luna", "model", "sol"]

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


async def image(
    prompt: str,
    images: list | None = None,
    model: str = "gpt-image-2.6-flare",
    size: str | None = None,
    quality: str | None = None,
    complexity: str | None = None,
    background: str | None = None,
):
    """Generates an image, returned as a ``views.Image``.

    ```python
    import chatgpt

    fox = await chatgpt.image("A watercolor fox")
    night = await chatgpt.image("Make it night", images=[fox], model="gpt-image-2.6-sunburst")
    ```

    An agent can draw by calling this from a ``agents.tool``. Generating images
    needs an OpenAI API key and is billed to it, even when signed in with ChatGPT,
    and what an option accepts depends on the image model.

    prompt: What to draw, or how to change `images`.
    images: Images to edit or take after: each a ``views.Image`` or bytes.
    model: The image model, such as "gpt-image-2.6-flare", the fastest, or "gpt-image-2.6-sunburst", the highest quality.
    size: Such as "1024x1024" or "1536x1024". Defaults to the model's choice.
    quality: Such as "low", "medium" or "high". Defaults to the model's choice.
    complexity: How much the model plans: "low", "medium" or "high".
    background: "transparent", "opaque" or "auto".
    """
    from views import Image

    references = [item if isinstance(item, bytes) else item.png() for item in images or []]
    data = await _chatgpt._generate_image(
        ChatGPTLanguageModel("gpt-6-luna", keychain.secret("OPENAI_API_KEY", prompt=_KEY_PROMPT)),
        prompt, references, model, size, quality, complexity, background,
    )
    return Image(data)


def astra() -> ChatGPTLanguageModel:
    """GPT-6 Astra: the most capable, for the most demanding work."""
    return model("gpt-6-astra")


def sol() -> ChatGPTLanguageModel:
    """GPT-6.1 Sol: near Astra for complex work, at a lower cost."""
    return model("gpt-6.1-sol")


def luna() -> ChatGPTLanguageModel:
    """GPT-6 Luna: the fastest and most cost-effective."""
    return model("gpt-6-luna")
