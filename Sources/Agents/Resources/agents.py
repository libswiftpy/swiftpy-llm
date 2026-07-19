import inspect
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

def tool(fn) -> Tool:
    """Create a Tool from a callable.
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
