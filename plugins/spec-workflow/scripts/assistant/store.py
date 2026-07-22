"""Session transcript store contract (SPEC-ASSISTANT.md §5a, §8.7, AST-014).

Stub only -- AST-014 fills this in: fsync'd JSONL append per turn plus a
rolling summary, such that a crash loses at most the in-flight turn. AST-010
creates this module only so the route table / lifecycle wiring has a name to
import against later -- no store logic lands here yet.
"""
