__doc__ = """Language model sessions and the tools they can call.

Create an ``agents.Agent``, optionally with instructions and tools, and await its
response. Decorate a regular or async function with ``agents.tool`` to let the
model call it.

```python
from agents import Agent, tool

@tool
def temperature(city: str) -> str:
    '''Look up the current temperature in a city.'''
    return "22 °C"

agent = Agent(tools=[temperature])
answer = await agent.respond("How warm is London?")
print(answer)
```

Use ``modeling.model`` to ask for a structured answer.

An agent runs on Private Cloud Compute when it is available and falls back to
the on-device model otherwise. Pass an ``agents.SystemLanguageModel`` as `model`
to pick one, ``agents.Skill`` objects as `skills` for guidance the model takes up
only when needed, and an ``agents.History`` as `history` to keep long
conversations within the model's context.

```python
from agents import Agent, History, SystemLanguageModel

agent = Agent(model=SystemLanguageModel.on_device(), history=History(rolling_window=10))
```"""
__all__ = ["Agent", "History", "LanguageModel", "Skill", "SystemLanguageModel", "SystemModelLocation", "tool"]

import inspect
from enum import Enum
from typing import Any, Callable


class SystemModelLocation(Enum):
    """Where a ``agents.SystemLanguageModel`` runs."""
    AUTOMATIC = "automatic"
    ON_DEVICE = "on-device"
    PRIVATE_CLOUD_COMPUTE = "private-cloud-compute"


from _agents import Agent, History, LanguageModel, Skill, SystemLanguageModel, Tool

# Report the public module, not the private one they live in.
for _type in (Agent, History, LanguageModel, Skill, SystemLanguageModel):
    _type.__module__ = __name__
del _type

@classmethod
def _args_from_json(cls, json_str):
    import json
    data = json.loads(json_str)
    obj = cls()
    obj._fields = data
    return obj

def _make_args_type(name, schema):
    class_template = "class " + name + ":\n    def __init__(self):\n        self._fields = {}\n"
    ns = {}
    exec(class_template, ns)
    Args = ns[name]
    Args._schema = schema
    Args._defaults = {}
    Args._from_json = _args_from_json
    return Args

def _resolve(ann):
    if isinstance(ann, str):
        import __main__
        return getattr(__main__, ann, ann)
    return ann

def _type_name(ann):
    return ann.__name__ if hasattr(ann, '__name__') else str(ann)

def tool(
    fn: Callable[..., Any] | None = None,
    *,
    input: Callable[..., Any] | None = None,
    output: Callable[[Any], Any] | None = None,
) -> Tool | Callable[[Callable[..., Any]], Tool]:
    """Turn a function into a Tool an Agent can call.

    fn: The function to expose. Its name becomes the tool name and its docstring
        is what the model reads to decide when to call it, so write one.
    input: Formats a call's input for its log, as ``agents.Tool.input`` does.
    output: Formats a call's result for its log, as ``agents.Tool.output`` does.

    Annotate every parameter: the annotations become the schema the model fills
    in. The function may be a coroutine, and whatever it returns is converted to
    a string for the model.

    ```python
    from agents import Agent, tool

    @tool
    def city_population(city: str) -> str:
        '''Look up how many people live in a city.'''
        return "8.3 million" if city == "London" else "unknown"

    agent = Agent(tools=[city_population])
    answer = await agent.respond("How many people live in London?")
    print(answer)
    ```

    A single parameter annotated with a ``modeling.model`` class is taken as the
    whole parameter set instead, which is how to give the model a schema with
    defaults.

    Calling the decorated name runs the original function, so a tool stays
    testable on its own.

    `input` takes the same arguments as the function and returns what an
    expanded call shows of them: a view, or a string shown as Markdown.
    `output` does the same for what the function returned, which otherwise
    shows in a plain code block.

    ````python
    @tool(input=lambda code: f"```python\\n{code}\\n```")
    def run(code: str) -> str:
        '''Runs Python code.'''
        ...
    ````
    """
    if fn is None:
        return lambda fn: tool(fn, input=input, output=output)

    made = _make_tool(fn)
    if input is not None:
        made.input(input)
    if output is not None:
        made.output(output)
    return made

def _make_tool(fn):
    sig = inspect.signature(fn)
    params = list(sig.parameters.items())

    # Single @model pattern: def fn(args: ModelClass)
    if len(params) == 1:
        ann = _resolve(params[0][1].annotation)
        if hasattr(ann, '_schema'):
            return Tool(ann, lambda args, fn=fn: _call(fn, args), fn)

    # Multi-param pattern: synthesize args class
    field_names = [name for name, _ in params]
    type_strs = {name: _type_name(_resolve(p.annotation)) for name, p in params}
    properties = [{"name": n, "type": type_strs[n]} for n in field_names]

    args_name = fn.__name__ + '_args'
    Args = _make_args_type(
        args_name,
        {"name": args_name, "properties": properties}
    )

    Args._tool_name = fn.__name__
    Args._tool_description = fn.__doc__ or ""

    # `fn` is the tool's own, or what `input` formats the arguments with.
    def wrapped(args, fn=fn):
        return _call(fn, *[args._fields[f] for f in field_names])

    return Tool(Args, wrapped, fn)

class _ToolFailure(Exception):
    """What a tool raised, as the traceback the model reads."""

def _failure(error):
    import traceback
    # Starts past this module's frame, and past the tool's own when it ran
    # code with exec or eval, or failed to compile it: that code is the
    # model's, the exec line isn't.
    frames = error.__traceback__.tb_next
    below = frames.tb_next if frames is not None else None
    if below is not None and below.tb_frame.f_code.co_name == "<module>":
        frames = below
    elif below is None and isinstance(error, SyntaxError):
        frames = None
    return _ToolFailure("".join(traceback.format_exception(type(error), error, frames)))

def _call(fn, *args):
    try:
        result = fn(*args)
    except Exception as error:
        raise _failure(error) from None
    return _awaited(result) if inspect.iscoroutine(result) else result

async def _awaited(coroutine):
    try:
        return await coroutine
    except Exception as error:
        raise _failure(error) from None
