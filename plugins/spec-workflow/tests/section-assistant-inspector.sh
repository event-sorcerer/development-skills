#!/usr/bin/env bash
# section-assistant-inspector.sh -- AST-044: voice-panel metrics expansion
# (SPEC-ASSISTANT.md §10.5, issue #330). Sourced by run-tests.sh; do not run
# standalone. Contract: the runner already defines set -uo pipefail and has
# sourced _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/
# fails/flaky before sourcing this file. This file assumes those are already
# in scope.
#
# Template-only: no engine change was needed for this task -- GET
# /assistant/metrics and GET /assistant/traces already return everything
# this fold needs (AST-043, #329). This section extracts and exercises the
# template's inspector functions, the same "extract() + eval() named
# functions against a stubbed DOM+fetch" harness style as
# section-assistant-chat.sh / section-assistant-selection.sh.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant inspector (AST-044: voice-panel metrics expansion, SPEC-ASSISTANT.md §10.5, issue #330) =="

echo "-- template: percentile estimation, turn grouping, waterfall geometry, error flagging, gated/offline, turn-click wiring --"
NVHTML_INSPECTOR="$PLUGIN/templates/neural-view.html"

_ai_node="$(mktemp).cjs"
cat >"$_ai_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

// DOM stub, same "getter-only children Proxy" shape as
// section-assistant-chat.sh's -- `.children.length = 0` on a real live
// HTMLCollection throws (getter, no setter); `_items` is the real backing
// array, appendChild/innerHTML= mutate it directly, `.children` is a Proxy
// that forwards reads but throws on any external `set`.
const elements = {};
function mkEl(initialId) {
    const el = {
        _id: initialId,
        _classes: new Set(),
        classList: {
            add(c){ this._parent._classes.add(c); },
            remove(c){ this._parent._classes.delete(c); },
            contains(c){ return this._parent._classes.has(c); },
        },
        disabled: false,
        title: "",
        textContent: "",
        value: "",
        style: {},
        _items: [],
        get children(){
            return new Proxy(this._items, {
                set(_target, prop){
                    throw new TypeError("Cannot set property " + String(prop) + " of #<Array> which has only a getter");
                },
            });
        },
        appendChild(child){ this._items.push(child); },
        get innerHTML(){ return this._innerHTML || ""; },
        set innerHTML(v){ this._items.length = 0; this._innerHTML = v; },
        get id(){ return this._id; },
        set id(v){ this._id = v; if (v) elements[v] = this; },
        remove(){ if (this._id && elements[this._id] === this) delete elements[this._id]; },
        get className(){ return [...this._classes].join(" "); },
        set className(v){ this._classes = new Set(v.split(" ").filter(Boolean)); },
        setAttribute(k, v){ this[k === "class" ? "className" : k] = v; this["_attr_" + k] = v; },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
    };
    if (initialId) elements[initialId] = el;
    return el;
}
function seedEl(id, className) {
    const el = mkEl(id);
    el.classList._parent = el;
    el.className = className;
    return el;
}
const document = {
    getElementById(id) {
        return elements[id] || null;
    },
    createElement(_tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        return el;
    },
};
global.window = global;

let fetchCalls = [];
let statusResponse = null;
let metricsResponse = { roots: {} };
let tracesResponse = { events: [] };
let statusThrows = false;
let metricsThrows = false;
global.fetch = async (url) => {
    fetchCalls.push({url});
    if (url === "/assistant/status") {
        if (statusThrows) throw new Error("network down");
        return { status: 200, json: async () => statusResponse };
    }
    if (url === "/assistant/metrics") {
        if (metricsThrows) throw new Error("network down");
        return { status: 200, json: async () => metricsResponse };
    }
    if (url === "/assistant/traces") {
        if (metricsThrows) throw new Error("network down");
        return { status: 200, json: async () => tracesResponse };
    }
    return { status: 200, json: async () => ({}) };
};

eval(extract("astMetricsBucketBoundaries"));
eval(extract("astMetricsBucketKey"));
eval(extract("astEstimatePercentile"));
eval(extract("astMetricsRootFor"));
eval(extract("astMetricsRow"));
eval(extract("buildAstMetricsGraphMarkup"));
eval(extract("renderAstMetrics"));
eval(extract("groupTurnsById"));
eval(extract("turnDurationMs"));
eval(extract("turnHasError"));
eval(extract("computeWaterfallSpans"));
eval(extract("renderAstTurnlist"));
eval(extract("renderAstWaterfall"));
eval(extract("selectAstTurn"));
eval(extract("renderAstInspectorGated"));
eval(extract("renderAstInspectorOffline"));
eval(extract("clearAstInspectorState"));
eval(extract("loadAssistantInspector"));

function resetInspector() {
    for (const id of ["ast-metrics-refresh", "ast-metrics-retry", "ast-metrics-state", "ast-metrics", "ast-turnlist", "ast-waterfall"]) {
        delete elements[id];
    }
    seedEl("ast-metrics-refresh", "iconbtn");
    seedEl("ast-metrics-retry", "iconbtn ast-metrics-retry ast-metrics-hidden");
    seedEl("ast-metrics-state", "ast-metrics-state");
    seedEl("ast-metrics", "ast-metrics");
    seedEl("ast-turnlist", "ast-turnlist");
    seedEl("ast-waterfall", "ast-waterfall ast-metrics-hidden");
    fetchCalls = [];
    statusThrows = false;
    metricsThrows = false;
    statusResponse = {outcome: "one", candidates: [{name: "jarvis", aliases: [], root: "/r"}], selected: "jarvis", gated: false, askAgain: false};
    metricsResponse = { roots: {} };
    tracesResponse = { events: [] };
    window.assistantInspector = { turns: [], selectedTurnId: null };
}

const TURN_EVENTS = [
    {kind: "turn.start", turn_id: "A", ts: "2024-01-01T00:00:00.000Z"},
    {kind: "recall.summary", turn_id: "A", ts: "2024-01-01T00:00:00.500Z"},
    {kind: "provider.call", turn_id: "A", ts: "2024-01-01T00:00:00.500Z", status: "ok"},
    {kind: "turn.end", turn_id: "A", ts: "2024-01-01T00:00:02.000Z", status: "ok"},
    {kind: "turn.start", turn_id: "B", ts: "2024-01-01T00:00:03.000Z"},
    {kind: "provider.error", turn_id: "B", ts: "2024-01-01T00:00:03.200Z", status: "error", payload: {error: "boom"}},
    {kind: "turn.end", turn_id: "B", ts: "2024-01-01T00:00:03.400Z", status: "error"},
];

(async () => {
    // ---- percentile estimation math, from a known cumulative-bucket fixture ----
    const bucketsMid = {"0.1": 0, "0.5": 2, "1": 5, "2": 8, "5": 10, "10": 10, "30": 10, "+Inf": 10};
    if (astEstimatePercentile(bucketsMid, 10, 0.5) !== 1) throw new Error("p50 mismatch: " + astEstimatePercentile(bucketsMid, 10, 0.5));
    if (astEstimatePercentile(bucketsMid, 10, 0.95) !== 4.25) throw new Error("p95 mismatch: " + astEstimatePercentile(bucketsMid, 10, 0.95));
    if (astEstimatePercentile({}, 0, 0.5) !== null) throw new Error("zero-count percentile must be null");
    const bucketsTail = {"0.1": 0, "0.5": 0, "1": 0, "2": 0, "5": 0, "10": 0, "30": 2, "+Inf": 10};
    if (astEstimatePercentile(bucketsTail, 10, 0.5) !== 30) throw new Error("past-last-finite-bucket estimate should be the last finite boundary (30), got " + astEstimatePercentile(bucketsTail, 10, 0.5));
    console.log("PERCENTILE_MATH_OK true");

    // ---- turn grouping + duration computation ----
    const turns = groupTurnsById(TURN_EVENTS);
    if (turns.length !== 2) throw new Error("expected 2 grouped turns, got " + turns.length);
    if (turns[0].turnId !== "A" || turns[1].turnId !== "B") throw new Error("turn order not preserved: " + JSON.stringify(turns.map(t => t.turnId)));
    if (turnDurationMs(turns[0]) !== 2000) throw new Error("turn A duration mismatch: " + turnDurationMs(turns[0]));
    if (turnHasError(turns[0])) throw new Error("turn A must not be flagged as error");
    if (!turnHasError(turns[1])) throw new Error("turn B (provider.error + status error) must be flagged as error");
    console.log("TURN_GROUPING_OK true");

    // ---- waterfall geometry: offsets/widths proportional to ts deltas, zero/unknown durations render as instants ----
    const spansA = computeWaterfallSpans(turns[0]);
    if (spansA.length !== 4) throw new Error("expected 4 spans for turn A, got " + spansA.length);
    if (spansA[0].offsetPct !== 0 || spansA[0].widthPct !== 25 || spansA[0].instant) throw new Error("span0 geometry wrong: " + JSON.stringify(spansA[0]));
    if (spansA[1].offsetPct !== 25 || !spansA[1].instant) throw new Error("span1 (zero-delta) should be an instant: " + JSON.stringify(spansA[1]));
    if (spansA[2].offsetPct !== 25 || spansA[2].widthPct !== 75 || spansA[2].instant) throw new Error("span2 geometry wrong: " + JSON.stringify(spansA[2]));
    if (spansA[3].offsetPct !== 100 || !spansA[3].instant) throw new Error("span3 (last event) should be an instant: " + JSON.stringify(spansA[3]));
    console.log("WATERFALL_GEOMETRY_OK true");

    // ---- error inline flagging: rendered bar carries the class + payload message as title ----
    resetInspector();
    renderAstWaterfall(turns[1]);
    const wfEl = document.getElementById("ast-waterfall");
    if (wfEl.classList.contains("ast-metrics-hidden")) throw new Error("rendering a turn must reveal the waterfall");
    const tracks = wfEl.children.filter(c => c.className.includes("ast-waterfall-track"));
    if (tracks.length !== 3) throw new Error("expected 3 tracks for turn B, got " + tracks.length);
    const errorBar = tracks[1].children.find(b => b.className.includes("ast-waterfall-error"));
    if (!errorBar) throw new Error("provider.error span must render with ast-waterfall-error");
    if (errorBar.title !== "boom") throw new Error("error bar title must carry the payload message verbatim: " + errorBar.title);
    console.log("ERROR_INLINE_OK true");

    // ---- gated branches: reuse the existing status-reason posture ----
    resetInspector();
    renderAstInspectorGated({outcome: "multiple", gated: true});
    let stateText = document.getElementById("ast-metrics-state").textContent;
    if (!document.getElementById("ast-metrics-state").className.includes("ast-metrics-state-gated")) throw new Error("gated (skip) must set the gated state class");
    if (!stateText || stateText.toLowerCase().indexOf("switcher") === -1) throw new Error("gated (skip) reason text missing: " + stateText);
    console.log("GATED_SKIP_OK true");

    resetInspector();
    renderAstInspectorGated({outcome: "none", gated: true});
    stateText = document.getElementById("ast-metrics-state").textContent;
    if (!stateText || stateText.toLowerCase().indexOf("no assistant") === -1) throw new Error("gated (none) reason text missing: " + stateText);
    console.log("GATED_NONE_OK true");

    // ---- offline branch: fetch failure shows a specific message + retry hook ----
    resetInspector();
    renderAstInspectorOffline();
    stateText = document.getElementById("ast-metrics-state").textContent;
    if (!stateText || stateText.toLowerCase().indexOf("offline") === -1) throw new Error("offline message missing: " + stateText);
    if (document.getElementById("ast-metrics-retry").className.includes("ast-metrics-hidden")) throw new Error("offline must reveal the retry affordance");
    console.log("OFFLINE_OK true");

    // ---- end-to-end: load wires metrics+turns, click wires the waterfall ----
    resetInspector();
    metricsResponse = { roots: { jarvis: {
        turnsByStatus: {ok: 1, error: 1},
        providerErrors: 1,
        eventsTotal: {turn: 4, recall: 1, provider: 2},
        distillBatches: 0,
        notesMinted: 0,
        turnDuration: {count: 1, sum: 2, buckets: {"0.1": 0, "0.5": 0, "1": 0, "2": 1, "5": 1, "10": 1, "30": 1, "+Inf": 1}},
    } } };
    tracesResponse = { events: TURN_EVENTS };
    await loadAssistantInspector();
    if (fetchCalls.filter(c => c.url === "/assistant/metrics").length !== 1) throw new Error("open must fetch /assistant/metrics exactly once");
    if (fetchCalls.filter(c => c.url === "/assistant/traces").length !== 1) throw new Error("open must fetch /assistant/traces exactly once");
    const metricsEl = document.getElementById("ast-metrics");
    // rows are built from two child <span>s (label, value) -- the stub's
    // `textContent` is a plain field (unlike a real DOM's auto-aggregating
    // one), so read it off the children the way the stub actually supports.
    const metricsRows = metricsEl.children.map(r => (r.children || []).map(c => c.textContent).join(" "));
    if (!metricsRows.some(t => t.indexOf("p50 turn duration") !== -1 && t.indexOf("1.50s") !== -1)) throw new Error("p50 row wrong: " + JSON.stringify(metricsRows));
    if (!metricsRows.some(t => t.indexOf("p95 turn duration") !== -1 && t.indexOf("1.95s") !== -1)) throw new Error("p95 row wrong: " + JSON.stringify(metricsRows));
    if (!metricsRows.some(t => t.indexOf("turns ok") !== -1 && t.indexOf("1") !== -1)) throw new Error("turns-ok row wrong: " + JSON.stringify(metricsRows));
    const graphHost = metricsEl.children.find(c => c.innerHTML && c.innerHTML.indexOf("ast-metrics-graph") !== -1);
    if (!graphHost) throw new Error("expected a structural ast-metrics-graph SVG placeholder to render");
    console.log("LOAD_METRICS_OK true");

    const turnlistEl = document.getElementById("ast-turnlist");
    if (turnlistEl.children.length !== 2) throw new Error("expected 2 turn rows, got " + turnlistEl.children.length);
    const rowB = turnlistEl.children.find(r => r.getAttribute("data-turn-id") === "B");
    if (!rowB || !rowB.className.includes("ast-turnlist-error")) throw new Error("turn B row must carry ast-turnlist-error");
    console.log("TURNLIST_OK true");

    if (!document.getElementById("ast-waterfall").classList.contains("ast-metrics-hidden")) throw new Error("waterfall must stay hidden before any turn is clicked");
    rowB.onclick();
    const wfAfterClick = document.getElementById("ast-waterfall");
    if (wfAfterClick.classList.contains("ast-metrics-hidden")) throw new Error("clicking a turn row must reveal the waterfall");
    const clickedTracks = wfAfterClick.children.filter(c => c.className.includes("ast-waterfall-track"));
    if (clickedTracks.length !== 3) throw new Error("waterfall after click should have 3 tracks (turn B's 3 events), got " + clickedTracks.length);
    const clickedError = clickedTracks[1].children.find(b => b.className.includes("ast-waterfall-error"));
    if (!clickedError || clickedError.title !== "boom") throw new Error("waterfall after click must still carry the error bar + title");
    const rowBAfter = turnlistEl.children.find(r => r.getAttribute("data-turn-id") === "B");
    if (!rowBAfter.className.includes("ast-turnlist-selected")) throw new Error("clicked row must be marked selected");
    console.log("TURN_CLICK_WIRING_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_inspector_out="$(node "$_ai_node" "$NVHTML_INSPECTOR" 2>&1)"
tmpl_inspector_rc=$?
rm -f "$_ai_node"
check_rc "inspector template script exits 0" 0 "$tmpl_inspector_rc"
check "template: percentile estimation from a known cumulative-bucket fixture" "PERCENTILE_MATH_OK true" "$tmpl_inspector_out"
check "template: turn grouping + duration computation from a fixture events list" "TURN_GROUPING_OK true" "$tmpl_inspector_out"
check "template: waterfall geometry (offsets/widths proportional, instants handled)" "WATERFALL_GEOMETRY_OK true" "$tmpl_inspector_out"
check "template: error events flag inline with the payload message as title" "ERROR_INLINE_OK true" "$tmpl_inspector_out"
check "template: gated (skip) shows the gate reason" "GATED_SKIP_OK true" "$tmpl_inspector_out"
check "template: gated (outcome none) shows the gate reason" "GATED_NONE_OK true" "$tmpl_inspector_out"
check "template: offline (fetch failure) shows a specific message with a retry hook" "OFFLINE_OK true" "$tmpl_inspector_out"
check "template: loading fetches metrics+traces once and renders percentile/counter rows + graph placeholder" "LOAD_METRICS_OK true" "$tmpl_inspector_out"
check "template: turn list renders grouped turns with an error hook class" "TURNLIST_OK true" "$tmpl_inspector_out"
check "template: clicking a turn wires the waterfall render" "TURN_CLICK_WIRING_OK true" "$tmpl_inspector_out"
if [[ "$tmpl_inspector_rc" -ne 0 ]]; then echo "$tmpl_inspector_out" >&2; fi

check "template pins the ast-metrics class name in source" '"ast-metrics"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-metrics-row class name in source" '"ast-metrics-row"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-metrics-graph class name in source" '"ast-metrics-graph"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-turnlist-row class name in source" '"ast-turnlist-row"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-waterfall class name in source" '"ast-waterfall"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-waterfall-error class name in source" "ast-waterfall-error" "$(cat "$NVHTML_INSPECTOR")"
