__doc__ = """Claude models for ``agents.Agent``.

Each function returns a model to pass as an agent's `model`. The Anthropic API
key is kept in the keychain under `ANTHROPIC_API_KEY`: the first call asks for
it, and its value never reaches Python.

```python
import claude
from agents import Agent

agent = Agent(model=claude.sonnet())
answer = await agent.respond("Name a pasta dish")
```"""
__all__ = ["ClaudeLanguageModel", "fable", "haiku", "model", "opus", "sonnet"]

import keychain
from _claude import ClaudeLanguageModel

ClaudeLanguageModel.__module__ = __name__


def model(name: str) -> ClaudeLanguageModel:
    """A Claude model by its ID.

    name: The model's ID, such as "claude-opus-4-8".
    """
    return ClaudeLanguageModel(name, keychain.secret("ANTHROPIC_API_KEY"))


def haiku() -> ClaudeLanguageModel:
    """The latest Claude Haiku: the fastest."""
    return model("claude-haiku-5-5")


def sonnet() -> ClaudeLanguageModel:
    """The latest Claude Sonnet: balances speed and intelligence."""
    return model("claude-sonnet-5-5")


def opus() -> ClaudeLanguageModel:
    """The latest Claude Opus: for the most demanding tasks."""
    return model("claude-opus-5-5")


def fable() -> ClaudeLanguageModel:
    """The latest Claude Fable."""
    return model("claude-fable-5-1")
