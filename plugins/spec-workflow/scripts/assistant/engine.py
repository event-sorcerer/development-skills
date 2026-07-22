"""AssistantEngine -- route table + worker-thread lifecycle owner
(SPEC-ASSISTANT.md §5a, AST-010, issue #308).

Per §5a the engine is the ONE thing neural-view.py mounts for `/assistant/*`:
neural-view.py's Handler delegates any such path to `AssistantEngine.handle()`
and otherwise stays untouched -- no request-handling logic for the assistant
lives in neural-view.py itself. `AssistantEngine` owns:

  - a route table (`handle(method, path, query, body)`) dispatched by an
    HTTP request thread; the request thread only enqueues work and reads
    already-computed state, per §5a's cross-thread rule below;
  - one long-lived worker thread per subsystem (distiller, tasks, traces,
    index), each in the `workers` registry as (name, Thread, stop_event) so
    tests can assert clean start/stop without an HTTP server. v1 (AST-010)
    workers are no-op heartbeats parked on `stop_event.wait()` -- the real
    per-subsystem loops arrive with their own tasks (distiller: E3,
    traces/index: E4/E6) and replace the worker body without touching this
    registry's shape;
  - a `queue.Queue` per subsystem (`queues[name]`), created now so HTTP
    request threads can enqueue-only into it later without the signature
    churning when the real workers land -- nothing drains these queues yet.

Isolation (§17.1): constructing/starting/stopping an engine never imports a
provider CLI and never spawns a subprocess -- `/assistant/status` in
particular must stay subprocess-free.

`start()`/`stop()` are both idempotent: `start()` on an already-started
engine is a no-op, and `stop()` may be called more than once (e.g. once from
an explicit shutdown path and once via `atexit`) without raising.
"""
import queue
import threading

from assistant import default_store
from assistant.store import SessionStore

# The four §5a-mandated subsystem workers this skeleton wires up. Real logic
# lands per-subsystem in later E1/E3/E4/E6 tasks; AST-010 only creates the
# named slot (thread + stop_event + queue) each of those tasks plugs into.
WORKER_NAMES = ("distiller", "tasks", "traces", "index")

# AST-014 /assistant/history?n=N: default window + hard cap so a client
# cannot force an unbounded read of the transcript (SessionStore.history's
# tail-read is a full-file read at v1 -- see store.py's docstring).
HISTORY_DEFAULT_N = 20
HISTORY_MAX_N = 500


def _heartbeat_worker(stop_event):
    """v1 no-op worker body: parks on `stop_event` until told to stop. No
    busy loop, no polling interval -- `wait()` blocks until `set()` is
    called. Replaced by a real per-subsystem loop in a later task."""
    stop_event.wait()


class AssistantEngine:
    """Owns the `/assistant/*` route table and the per-subsystem worker
    threads. One instance is constructed per server process (neural-view.py's
    `serve` branch) and started/stopped alongside the server's own
    lifecycle."""

    def __init__(self, repos_getter, state_dir):
        """`repos_getter` is a zero-arg callable returning the CURRENT
        (name, root) repo list at call time -- not a snapshot. neural-view.py
        passes `lambda: REPOS` so a marker added after boot and picked up by
        `rescan_loop`'s reassignment of the module-level REPOS (see
        neural-view.py's rescan_loop docstring) is reflected on the very next
        `/assistant/status` poll, instead of the engine forever counting
        against whatever REPOS held at construction time."""
        self._repos_getter = repos_getter
        self.state_dir = state_dir
        self.queues = {name: queue.Queue() for name in WORKER_NAMES}
        self.workers = []  # [(name, Thread, stop_event), ...] -- see start()
        self._lock = threading.Lock()

    def start(self):
        """Launch the worker registry. Idempotent: a second call while
        already started is a no-op (does not spawn duplicate workers)."""
        with self._lock:
            if self.workers:
                return
            workers = []
            for name in WORKER_NAMES:
                stop_event = threading.Event()
                thread = threading.Thread(
                    target=_heartbeat_worker,
                    args=(stop_event,),
                    name=f"assistant-{name}",
                    daemon=False,
                )
                thread.start()
                workers.append((name, thread, stop_event))
            self.workers = workers

    def stop(self, timeout=5.0):
        """Signal every worker's stop_event and join each with a bounded
        timeout, so a server shutdown never hangs on a stuck worker.
        Idempotent: safe to call again (or on an engine that was never
        started) -- a second call just finds nothing left to stop."""
        with self._lock:
            workers, self.workers = self.workers, []
        for _, _, stop_event in workers:
            stop_event.set()
        for _, thread, _ in workers:
            thread.join(timeout=timeout)

    # --- route table --------------------------------------------------------

    def handle(self, method, path, query=None, body=None):
        """Dispatch one `/assistant/*` request. `path` must already be
        confirmed by the caller to start with "/assistant/" (neural-view.py's
        Handler does this before delegating). Returns
        `(status, payload, content_type)` on a match, or `None` if nothing
        matched -- the caller is responsible for turning that into a 404."""
        if method == "GET" and path == "/assistant/status":
            return 200, self._status(), "application/json"
        if method == "GET" and path == "/assistant/history":
            return 200, self._history(query), "application/json"
        return None

    def _status(self):
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        return {
            "engine": "ok",
            "workers": [
                {"name": name, "alive": thread.is_alive()}
                for name, thread, _ in self.workers
            ],
            "assistants": len(candidates),
            "selected": None,
        }

    def _history(self, query):
        """GET /assistant/history?n=N -- last N exchanges of the resolved
        assistant's session transcript. The store is constructed FRESH on
        every call (never held on `self`) for the same reason `_status`
        re-discovers candidates every call: `self._repos_getter()` is a
        live getter, not a ctor-time snapshot (see __init__'s docstring),
        so a marker added/removed after boot must be reflected on the very
        next poll -- caching a store instance would pin it to whatever
        root resolved first and go stale exactly like a ctor-time repos
        snapshot would.
        """
        n = _parse_history_n(query)
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        try:
            root, _section = default_store.resolve_assistant(candidates, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            # No assistant unambiguously resolved (none discovered, or
            # multiple with no stored default) -- an empty, explained
            # result rather than a 404/500; §5a routes never crash on an
            # absent selection, matching /assistant/status's `selected:
            # None` treatment of the same not-yet-selected state.
            return {"exchanges": [], "warnings": [f"no assistant resolved: {exc}"]}
        return SessionStore(root).history(n)


def _parse_history_n(query):
    raw = None
    if query:
        values = query.get("n")
        if values:
            raw = values[0]
    if raw is None:
        return HISTORY_DEFAULT_N
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return HISTORY_DEFAULT_N
    if n < 0:
        return 0
    return min(n, HISTORY_MAX_N)
