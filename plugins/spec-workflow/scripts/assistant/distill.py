"""Distiller subsystem contract (SPEC-ASSISTANT.md §5a, E3).

Stub only -- a later E3 task fills this in with the real distillation loop
that the `distiller` worker (see engine.py's WORKER_NAMES) will run instead
of its v1 heartbeat no-op. AST-010 creates this module only so the worker
registry has a name to import against later -- no distiller logic lands here
yet.
"""
