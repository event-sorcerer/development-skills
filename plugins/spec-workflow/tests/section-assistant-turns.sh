#!/usr/bin/env bash
# section-assistant-turns.sh -- AST-013: turn pipeline -- context builder +
# budgets + recall injection (SPEC-ASSISTANT.md Sec8.2, Sec8.3, Sec9.1,
# issue #311). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant turn pipeline (AST-013: context builder + budgets + recall injection, SPEC-ASSISTANT.md Sec8.2/Sec8.3/Sec9.1) =="

AT_SCRIPTS="$PLUGIN/scripts"

# ------------------------------------------------------- (1) basic compose: ordering + shapes
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import sys
from assistant import turns

persona_cfg = {
    "systemPrompt": "You are Jarvis, terse and helpful.",
    "names": ["Jarvis", "J"],
    "llm": {"provider": "claude", "model": "claude-fable-5"},
}

def roster_provider():
    return [{"name": "search", "one-liner": "web search", "available": True}]

def recall_fn(message):
    return {"blocks": ["### note-one  [strength 2]\nbody text"], "seeds": 1, "injected": 1, "links_fired": []}

session_state = {"summary": "prior recap", "turns": [{"role": "user", "text": "hi"}, {"role": "assistant", "text": "hello"}]}

result = turns.compose_context(persona_cfg, roster_provider, recall_fn, session_state, "what's the weather?")

ctx = result["context_for_adapter"]
sys_text = ctx["system"]
print("HAS_KEYS", sorted(result.keys()) == ["budget_report", "chips", "context_for_adapter"])
print("INPUT_IS_RAW", ctx["input"] == "what's the weather?")
print("MODEL_PASSED", ctx.get("model") == "claude-fable-5")
print("PERSONA_BEFORE_ROSTER", sys_text.find("Jarvis, terse") < sys_text.find("search"))
print("ROSTER_BEFORE_SUMMARY", sys_text.find("search") < sys_text.find("prior recap"))
print("SUMMARY_BEFORE_NOTES", sys_text.find("prior recap") < sys_text.find("note-one"))
print("NOTES_BEFORE_TURNS", sys_text.find("note-one") < sys_text.find("hello"))
print("NAMES_ALIAS_PRESENT", "J" in sys_text)
print("CHIPS", result["chips"])
print("BUDGET_TOTAL_CAP", result["budget_report"]["total_cap"])
print("NOT_OVER_BUDGET", result["budget_report"]["over_budget"] is False)
PY
)"
check "compose: returns exactly the three documented top-level keys" "HAS_KEYS True" "$out"
check "compose: input carries the RAW user message verbatim" "INPUT_IS_RAW True" "$out"
check "compose: model passed through from persona_cfg.llm.model" "MODEL_PASSED True" "$out"
check "compose: persona precedes roster in system text" "PERSONA_BEFORE_ROSTER True" "$out"
check "compose: roster precedes rolling summary in system text" "ROSTER_BEFORE_SUMMARY True" "$out"
check "compose: rolling summary precedes recalled notes in system text (AST-032 note-wins ordering)" "SUMMARY_BEFORE_NOTES True" "$out"
check "compose: recalled notes precede last-N turns in system text" "NOTES_BEFORE_TURNS True" "$out"
check "compose: name alias rendered into system text" "NAMES_ALIAS_PRESENT True" "$out"
check "compose: chips derived from recall blocks" "'slug': 'note-one', 'strength': 2" "$out"
check "compose: budget_report.total_cap is the documented ~6k token budget" "BUDGET_TOTAL_CAP 6000" "$out"
check "compose: small inputs never trip over_budget" "NOT_OVER_BUDGET True" "$out"

# ------------------------------------------------------- (2) empty roster placeholder + missing recall
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"systemPrompt": "P", "names": ["Solo"]}
result = turns.compose_context(persona_cfg, None, None, {}, "hello")
print("PLACEHOLDER_NOTE", "AST-061" in result["context_for_adapter"]["system"])
print("NO_MODEL_KEY", "model" not in result["context_for_adapter"])
print("EMPTY_CHIPS", result["chips"] == [])
PY
)"
check "compose: default roster provider renders a documented placeholder" "PLACEHOLDER_NOTE True" "$out"
check "compose: model key omitted when persona_cfg has no llm.model" "NO_MODEL_KEY True" "$out"
check "compose: no recall_fn -> empty chips, no crash" "EMPTY_CHIPS True" "$out"

# ------------------------------------------------------- (3) raw message reaches recall_fn untransformed
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

seen = []
def recall_fn(message):
    seen.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}

raw = "  Weird Casing AND trailing spaces   "
turns.compose_context({}, None, recall_fn, {}, raw)
print("RAW_MATCH", seen == [raw])
PY
)"
check "compose: recall_fn receives the message byte-identical (no lower/strip)" "RAW_MATCH True" "$out"

# ------------------------------------------------------- (4) budget: per-component caps hold under oversized inputs
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"systemPrompt": "P" * 100000, "names": ["N" * 100000]}

def roster_provider():
    return [{"name": "cap%d" % i, "one-liner": "x" * 500, "available": True} for i in range(50)]

def recall_fn(message):
    return {"blocks": ["### note-%d  [strength 1]\n%s" % (i, "y" * 2000) for i in range(20)],
            "seeds": 20, "injected": 20, "links_fired": []}

session_state = {
    "summary": "S" * 100000,
    "turns": [{"role": "user", "text": "T" * 2000} for _ in range(6)],
}

result = turns.compose_context(persona_cfg, roster_provider, recall_fn, session_state, "short msg")
comp = result["budget_report"]["components"]
ok = True
for name in ("persona", "roster", "notes", "summary", "turns"):
    if comp[name]["tokens"] > comp[name]["cap"]:
        ok = False
        print("OVER", name, comp[name])
print("ALL_COMPONENTS_WITHIN_CAP", ok)
print("ALL_CLIPPED", sorted(result["budget_report"]["clipped_components"]))
print("USER_MSG_NEVER_CLIPPED", comp["user_message"]["clipped"] is False)
print("USER_MSG_UNCAPPED", comp["user_message"]["cap"] is None)
PY
)"
check "budget: every oversized component stays within its own cap" "ALL_COMPONENTS_WITHIN_CAP True" "$out"
check "budget: all five itemized components report clipped=True" "ALL_CLIPPED ['notes', 'persona', 'roster', 'summary', 'turns']" "$out"
check "budget: user_message component is never clipped" "USER_MSG_NEVER_CLIPPED True" "$out"
check "budget: user_message component has no cap (documented exception)" "USER_MSG_UNCAPPED True" "$out"

# ------------------------------------------------------- (5) user message survives verbatim even when huge
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

huge = "U" * 50000
result = turns.compose_context({}, None, None, {}, huge)
print("VERBATIM", result["context_for_adapter"]["input"] == huge)
print("OVER_BUDGET_TRUE", result["budget_report"]["over_budget"] is True)
PY
)"
check "budget: a huge user message is never truncated" "VERBATIM True" "$out"
check "budget: a huge user message honestly reports over_budget" "OVER_BUDGET_TRUE True" "$out"

# ------------------------------------------------------- (6) clip precedence: notes rank-order prefix
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

# notes cap is 1500 tokens = 6000 chars. Blocks are ~2924 chars each
# (header + 2900-char body); two fit under the "\n\n"-joined 6000-char cap
# (2924+2+2924=5850), a third does not (+2+2924=8776).
def recall_fn(message):
    return {"blocks": ["### first  [strength 3]\n" + "a" * 2900,
                        "### second  [strength 2]\n" + "b" * 2900,
                        "### third  [strength 1]\n" + "c" * 2900],
            "seeds": 3, "injected": 3, "links_fired": []}

result = turns.compose_context({}, None, recall_fn, {}, "q")
sys_text = result["context_for_adapter"]["system"]
print("FIRST_IN", "first" in sys_text)
print("SECOND_IN", "second" in sys_text)
print("THIRD_OUT", "third" not in sys_text)
print("CHIPS_INCLUDE_ALL_THREE", [c["slug"] for c in result["chips"]] == ["first", "second", "third"])
PY
)"
check "clip precedence: notes -- higher-rank blocks kept" "FIRST_IN True" "$out"
check "clip precedence: notes -- second block still fits" "SECOND_IN True" "$out"
check "clip precedence: notes -- lowest-rank block dropped once cap exceeded" "THIRD_OUT True" "$out"
check "clip precedence: chips reflect ALL recalled notes (pre-budget-clip transparency)" "CHIPS_INCLUDE_ALL_THREE True" "$out"

# ------------------------------------------------------- (7) clip precedence: turns oldest-first
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

# turns cap is 2000 tokens = 8000 chars. Six turns of 2000 chars each
# (12000 total) -- oldest ones must drop, newest survive.
session_state = {"turns": [{"role": "user", "text": "MSG%d-%s" % (i, "x" * 1990)} for i in range(6)]}
result = turns.compose_context({}, None, None, session_state, "q")
sys_text = result["context_for_adapter"]["system"]
print("OLDEST_DROPPED", "MSG0-" not in sys_text)
print("NEWEST_KEPT", "MSG5-" in sys_text)
print("CHRONO_ORDER", sys_text.find("MSG4-") < sys_text.find("MSG5-") if "MSG4-" in sys_text else True)
PY
)"
check "clip precedence: turns -- oldest entry dropped" "OLDEST_DROPPED True" "$out"
check "clip precedence: turns -- newest entry kept" "NEWEST_KEPT True" "$out"
check "clip precedence: turns -- surviving entries stay in chronological order" "CHRONO_ORDER True" "$out"

# ------------------------------------------------------- (8) turns window: only last N<=6 considered
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

session_state = {"turns": [{"role": "user", "text": "OLD%d" % i} for i in range(10)]}
result = turns.compose_context({}, None, None, session_state, "q")
sys_text = result["context_for_adapter"]["system"]
print("N6_EXCLUDES_OLD0", "OLD0" not in sys_text)
print("N6_EXCLUDES_OLD3", "OLD3" not in sys_text)
print("N6_INCLUDES_OLD9", "OLD9" in sys_text)
PY
)"
check "turns window: entries before the last N=6 are excluded outright" "N6_EXCLUDES_OLD0 True" "$out"
check "turns window: N=6 boundary excludes the 4th-from-last entry" "N6_EXCLUDES_OLD3 True" "$out"
check "turns window: the very last entry is always included" "N6_INCLUDES_OLD9 True" "$out"

# ------------------------------------------------------- (9) query-embed cache hit/miss counting
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

calls = []
def recall_fn(message):
    calls.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}

cache = turns.QueryEmbedCache()
turns.compose_context({}, None, recall_fn, {}, "same message", cache=cache)
turns.compose_context({}, None, recall_fn, {}, "same message", cache=cache)
turns.compose_context({}, None, recall_fn, {}, "different message", cache=cache)
print("CALL_COUNT", len(calls))

# no cache passed -> fresh ephemeral cache each call -> no cross-call caching
calls2 = []
def recall_fn2(message):
    calls2.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}
turns.compose_context({}, None, recall_fn2, {}, "x")
turns.compose_context({}, None, recall_fn2, {}, "x")
print("NO_CACHE_CALL_COUNT", len(calls2))
PY
)"
check "cache: repeated identical message hits the cache (recall called once, then a distinct miss)" "CALL_COUNT 2" "$out"
check "cache: omitting cache means no cross-call memoization" "NO_CACHE_CALL_COUNT 2" "$out"

# ------------------------------------------------------- (10) TTL expiry via injectable clock
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

calls = []
def recall_fn(message):
    calls.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}

clock = {"t": 0.0}
cache = turns.QueryEmbedCache(ttl_seconds=10, now=lambda: clock["t"])
turns.compose_context({}, None, recall_fn, {}, "m", cache=cache)
clock["t"] = 5.0
turns.compose_context({}, None, recall_fn, {}, "m", cache=cache)  # still within TTL -> hit
clock["t"] = 20.0
turns.compose_context({}, None, recall_fn, {}, "m", cache=cache)  # expired -> miss
print("CALL_COUNT", len(calls))
PY
)"
check "cache: TTL expiry forces a fresh recall after the window elapses" "CALL_COUNT 2" "$out"

# ------------------------------------------------------- (11) run_turn: fake adapter, chips, session round trip
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"systemPrompt": "P", "names": ["N"], "llm": {"provider": "fake", "model": "m1"}}

seen_context = {}
def fake_adapter(context, **kwargs):
    seen_context.update(context)
    return {"text": "echo:" + context["input"], "usage": {"input_tokens": 3}, "timings": {"elapsed_seconds": 0.01}}

def get_adapter(provider):
    assert provider == "fake"
    return fake_adapter

def recall_fn(message):
    return {"blocks": ["### note-x  [strength 5]\nbody"], "seeds": 1, "injected": 1, "links_fired": []}

session_state = {"summary": "", "turns": [], "turn_count": 0}
result = turns.run_turn(persona_cfg, None, recall_fn, session_state, "hello there", get_adapter=get_adapter)

print("HAS_KEYS", sorted(result.keys()) == ["budget_report", "chips", "text", "timings", "updated_session_state", "usage"])
print("TEXT", result["text"])
print("CHIPS_SLUG", result["chips"][0]["slug"])
print("USAGE", result["usage"])
print("SESSION_TURNS_LEN", len(result["updated_session_state"]["turns"]))
print("SESSION_TURN_COUNT", result["updated_session_state"]["turn_count"])
print("SESSION_LAST_USER", result["updated_session_state"]["turns"][-2])
print("SESSION_LAST_ASSISTANT", result["updated_session_state"]["turns"][-1])
print("ADAPTER_SAW_MODEL", seen_context.get("model"))
PY
)"
check "run_turn: returns exactly the documented five keys plus additive budget_report" "HAS_KEYS True" "$out"
check "run_turn: text comes from the adapter's completion" "TEXT echo:hello there" "$out"
check "run_turn: chips surface in the reply payload" "CHIPS_SLUG note-x" "$out"
check "run_turn: usage passed through from the adapter" "USAGE {'input_tokens': 3}" "$out"
check "run_turn: session_state round trip appends both turns" "SESSION_TURNS_LEN 2" "$out"
check "run_turn: session_state turn_count increments by one exchange" "SESSION_TURN_COUNT 1" "$out"
check "run_turn: appended user entry" "SESSION_LAST_USER {'role': 'user', 'text': 'hello there'}" "$out"
check "run_turn: appended assistant entry" "SESSION_LAST_ASSISTANT {'role': 'assistant', 'text': 'echo:hello there'}" "$out"
check "run_turn: adapter receives model from persona_cfg.llm.model" "ADAPTER_SAW_MODEL m1" "$out"

# ------------------------------------------------------- (12) K-turn summary refresh trigger + size cap
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"llm": {"provider": "fake"}}

def fake_adapter(context, **kwargs):
    return {"text": "reply", "usage": None, "timings": {"elapsed_seconds": 0.0}}

def get_adapter(provider):
    return fake_adapter

summarizer_calls = []
def counting_summarizer(old_summary, window, cap_chars):
    summarizer_calls.append((old_summary, len(window), cap_chars))
    return ("REFRESHED-" + str(len(summarizer_calls))) * 5000  # oversized on purpose -> must be capped

session_state = {"summary": "", "turns": [], "turn_count": 0}
for i in range(7):
    result = turns.run_turn(persona_cfg, None, None, session_state, "msg%d" % i,
                             get_adapter=get_adapter, summarizer=counting_summarizer, refresh_every=8)
    session_state = result["updated_session_state"]
    if i < 6:
        print("NO_REFRESH_YET_%d" % i, session_state["summary"] == "")

# 8th call (i=7) crosses the K=8 boundary -> refresh fires
result = turns.run_turn(persona_cfg, None, None, session_state, "msg7",
                         get_adapter=get_adapter, summarizer=counting_summarizer, refresh_every=8)
session_state = result["updated_session_state"]
print("REFRESH_FIRED", len(summarizer_calls) == 1)
print("TURN_COUNT_AT_REFRESH", session_state["turn_count"])
print("SUMMARY_SIZE_CAPPED", len(session_state["summary"]) <= turns.DEFAULT_COMPONENT_BUDGETS["summary"] * turns.TOKENS_CHARS_PER_TOKEN)
PY
)"
check "summary refresh: no refresh before the Kth turn" "NO_REFRESH_YET_0 True" "$out"
check "summary refresh: still none at turn 6" "NO_REFRESH_YET_5 True" "$out"
check "summary refresh: fires exactly once at the Kth turn" "REFRESH_FIRED True" "$out"
check "summary refresh: turn_count reflects 8 completed exchanges" "TURN_COUNT_AT_REFRESH 8" "$out"
check "summary refresh: refreshed summary is size-capped" "SUMMARY_SIZE_CAPPED True" "$out"

# ------------------------------------------------------- (13) default_summarizer is documented + capped
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

window = [{"role": "user", "text": "hi"}, {"role": "assistant", "text": "hello"}]
result = turns.default_summarizer("prior", window, 20)
print("CAPPED_LEN", len(result) <= 20)
print("STARTS_WITH_PRIOR", result.startswith("prior"))
PY
)"
check "default_summarizer: respects cap_chars" "CAPPED_LEN True" "$out"
check "default_summarizer: extractive -- prior summary text leads" "STARTS_WITH_PRIOR True" "$out"

# ------------------------------------------------------- (13b) AST-032: stale-summary regression fixture --
# a rolling summary asserting X ("deploy target is us-east-1") alongside a
# FRESHER recalled note asserting not-X ("deploy target is eu-west-1"). This
# does not assert anything about model behavior (no model runs here) -- it
# asserts the documented note-wins MECHANISM: the assembled system prompt
# places the note strictly after the summary, so prompt-order recency lets
# the fresher note win over the stale summary blob.
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

session_state = {
    "summary": "Recap: the deploy target is us-east-1.",
    "turns": [],
}

def recall_fn(message):
    return {"blocks": ["### deploy-target-note  [strength 4]\nThe deploy target is now eu-west-1 (updated)."],
            "seeds": 1, "injected": 1, "links_fired": []}

result = turns.compose_context({}, None, recall_fn, session_state, "where do we deploy?")
sys_text = result["context_for_adapter"]["system"]
print("BOTH_PRESENT", "us-east-1" in sys_text and "eu-west-1" in sys_text)
print("NOTE_AFTER_SUMMARY", sys_text.find("us-east-1") < sys_text.find("eu-west-1"))
PY
)"
check "AST-032 regression: stale summary and fresher note both survive budget" "BOTH_PRESENT True" "$out"
check "AST-032 regression: note-wins -- fresher note ordered after the stale summary" "NOTE_AFTER_SUMMARY True" "$out"

# ------------------------------------------------------- (14) integration-ish: real brain.recall against a scaffolded temp brain
AT_ROOT="$(mktemp -d)"
AT_IDENTITIES="$AT_ROOT/.claude/identities"
mkdir -p "$AT_IDENTITIES"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$AT_ROOT" "$AT_IDENTITIES" <<'PY'
import sys
root, identities = sys.argv[1], sys.argv[2]
import brain
from assistant import turns

brain.mint(identities, "assistant", "weather-api-note", root,
           "Use the weather.gov API, not a scraped page.\n",
           tags="weather,forecast", paths="")

recall_fn = turns.make_default_recall(identities, root, role="assistant")
result = turns.compose_context({}, None, recall_fn, {}, "weather forecast question")
print("CHIP_SLUGS", [c["slug"] for c in result["chips"]])
print("NOTE_IN_SYSTEM", "weather-api-note" in result["context_for_adapter"]["system"])
PY
)"
check "integration: real brain.recall surfaces the minted note as a chip" "CHIP_SLUGS ['weather-api-note']" "$out"
check "integration: the recalled note text lands in the composed system prompt" "NOTE_IN_SYSTEM True" "$out"
rm -rf "$AT_ROOT"

# ------------------------------------------------------- (15) turns pipeline never touches engine queues
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import inspect
from assistant import turns

import assistant.turns as turns_module
code_only = "\n".join(
    line for line in inspect.getsource(turns_module).splitlines()
    if not line.strip().startswith("#")
)
print("NO_ENGINE_IMPORT", "import engine" not in code_only and "from assistant import engine" not in code_only)
print("NO_QUEUE_TOUCH", "queues[" not in code_only and "import queue" not in code_only)
PY
)"
check "invariant: turns.py never imports engine.py" "NO_ENGINE_IMPORT True" "$out"
check "invariant: turns.py never touches a queues[name] slot (Sec9.5/Sec17.7)" "NO_QUEUE_TOUCH True" "$out"

# --- review r2 finding 1: the DEFAULT budget constants themselves are a
# load-bearing invariant (sum of per-component caps < total, headroom for the
# user message) -- previously every budget test passed explicit overrides, so
# a 10x default blowout kept the suite green. These checks import the real
# constants. ------------------------------------------------------------------
at_r2_out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
total = turns.TOKEN_BUDGET_TOTAL
caps = dict(turns.DEFAULT_COMPONENT_BUDGETS)
print("TOTAL", total)
print("CAP_SUM", sum(caps.values()))
print("SUM_UNDER_TOTAL", sum(caps.values()) < total)
print("HEADROOM_AT_LEAST_500", total - sum(caps.values()) >= 500)
print("CAP_KEYS", ",".join(sorted(caps)))
PY
)"
at_r2_rc=$?
check_rc "r2: budget-constants probe runs" 0 "$at_r2_rc"
check "r2: total budget is the documented ~6k" "TOTAL 6000" "$at_r2_out"
check "r2: per-component caps sum under the total (headroom invariant)" "SUM_UNDER_TOTAL True" "$at_r2_out"
check "r2: headroom is at least 500 tokens for the user message" "HEADROOM_AT_LEAST_500 True" "$at_r2_out"
check "r2: cap keys are exactly the five documented components" "CAP_KEYS notes,persona,roster,summary,turns" "$at_r2_out"

# --- review r2 finding 2 companion: dense-script (CJK) text must not be
# undercounted at chars/4 -- the estimator charges high codepoints 1 token
# each. 12 CJK chars must estimate >= 12 tokens, not 3. -----------------------
at_r2b_out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
cjk = "测试" * 6
print("CJK_TOKENS_GE_12", turns.estimate_tokens(cjk) >= 12)
print("ASCII_UNCHANGED", turns.estimate_tokens("abcdefgh") == 2)
PY
)"
check "r2: CJK text charged at least 1 token per char" "CJK_TOKENS_GE_12 True" "$at_r2b_out"
check "r2: ASCII estimation unchanged by the dense-script rule" "ASCII_UNCHANGED True" "$at_r2b_out"
