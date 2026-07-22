"""Provider adapter contract (SPEC-ASSISTANT.md §5a, §8.4-§8.5).

Stub only -- AST-011 (codex.py) and AST-012 (claude.py) fill this in. The
mandated contract each adapter will implement:

    complete(context) -> {text, usage, timings}

Per §17.3 adapters invoke provider CLIs via argv-array only (never a shell
string), with pinned isolation flags (§8.4) and a mandatory timeout (§8.5).
AST-010 creates this module only so the route table / lifecycle wiring has a
name to import against later -- no adapter logic lands here yet.
"""
