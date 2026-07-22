"""Task queue subsystem contract (SPEC-ASSISTANT.md §5a, E6).

Stub only -- a later E6 task fills this in with the real task-queue loop
that the `tasks` worker (see engine.py's WORKER_NAMES) will run instead of
its v1 heartbeat no-op. AST-010 creates this module only so the worker
registry has a name to import against later -- no task-queue logic lands
here yet.
"""
