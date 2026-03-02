"""Publisher registry.

Resolves a PUBLISH_TARGET name to the corresponding BasePublisher subclass.
"""

from .base import BasePublisher

# Lazy imports to avoid pulling in deps for unused publishers.
_REGISTRY: dict[str, tuple[str, str]] = {
    # target_name → (module_path, class_name)
    "clickup": (".clickup", "ClickUpPublisher"),
    "confluence": (".confluence", "ConfluencePublisher"),
}


def get_publisher(target: str) -> BasePublisher:
    """Instantiate and return a publisher for the given target name.

    Raises ValueError if the target is not registered, or KeyError from the
    publisher __init__ if required env vars are missing.
    """
    if target not in _REGISTRY:
        available = ", ".join(sorted(_REGISTRY))
        raise ValueError(
            f"Unknown publish target: {target!r}. Available: {available}"
        )

    module_path, class_name = _REGISTRY[target]

    # Import the module relative to this package
    import importlib

    module = importlib.import_module(module_path, package=__package__)
    cls = getattr(module, class_name)
    return cls()


def available_targets() -> list[str]:
    """Return the list of registered publisher target names."""
    return sorted(_REGISTRY)
