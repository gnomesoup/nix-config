# ruff: noqa: N999 - Hermes directory plugins intentionally use kebab-case names.
"""Inigo's Zulip messaging platform plugin."""


def register(ctx):
    from .adapter import register as register_adapter

    register_adapter(ctx)
