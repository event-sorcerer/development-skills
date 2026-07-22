"""Observability / traces subsystem contract (SPEC-ASSISTANT.md §5a, E4).

Stub only -- a later E4 task fills this in with the real traces-writer loop
that the `traces` worker (see engine.py's WORKER_NAMES) will run instead of
its v1 heartbeat no-op. AST-010 creates this module only so the worker
registry has a name to import against later -- no traces/prometheus logic
lands here yet.
"""
