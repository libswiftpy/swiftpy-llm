__doc__ = """Language model sessions and the tools they can call.

Create an ``agents.Agent``, optionally with instructions and tools, and await its
response. Decorate a regular or async function with ``agents.tool`` to let the
model call it.

```python
from agents import Agent, tool

@tool
async def temperature(city: str) -> str:
    '''Look up the current temperature in a city.'''
    return "22 °C"

agent = Agent(tools=[temperature])
answer = await agent.respond("How warm is London?")
print(answer)
```

Use ``modeling.model`` to ask for a structured answer.

On iOS 27 and later an agent runs on Private Cloud Compute when it is available
and falls back to the on-device model otherwise."""
__all__ = ["Agent", "tool"]

import inspect
from typing import Any, Callable
from agents.native import Agent, Tool

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

def tool(fn: Callable[..., Any]) -> Tool:
    """Turn a function into a Tool an Agent can call.

    fn: The function to expose. Its name becomes the tool name and its docstring
        is what the model reads to decide when to call it, so write one.

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
    """
    sig = inspect.signature(fn)
    params = list(sig.parameters.items())

    # Single @model pattern: def fn(args: ModelClass)
    if len(params) == 1:
        ann = _resolve(params[0][1].annotation)
        if hasattr(ann, '_schema'):
            return Tool(ann, fn, fn)

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

    def wrapped(args):
        return fn(*[args._fields[f] for f in field_names])

    return Tool(Args, wrapped, fn)
