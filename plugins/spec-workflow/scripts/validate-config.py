#!/usr/bin/env python3
"""Validate .claude/project.json (schemaVersion 1) with actionable error messages.

Usage: validate-config.py <path-to-project.json>
Exit 0 = valid (prints a summary); exit 1 = invalid (prints every problem found).
Structural validation only — no third-party deps.
"""
import json
import re
import sys

errs = []


def need(obj, key, typ, where):
    if key not in obj:
        errs.append(f"{where}: missing required key '{key}'")
        return None
    if typ and not isinstance(obj[key], typ):
        errs.append(f"{where}.{key}: expected {typ.__name__}, got {type(obj[key]).__name__}")
        return None
    return obj[key]


def main(path):
    try:
        cfg = json.load(open(path))
    except Exception as e:  # noqa: BLE001
        print(f"INVALID: cannot parse {path}: {e}")
        return 1

    if cfg.get("schemaVersion") != 1:
        errs.append(f"schemaVersion must be 1 (got {cfg.get('schemaVersion')!r})")

    proj = need(cfg, "project", dict, "$") or {}
    for k in ("name", "mainBranch", "branchPattern"):
        need(proj, k, str, "project")

    boards = need(cfg, "boards", list, "$") or []
    board_ids = set()
    for i, b in enumerate(boards):
        w = f"boards[{i}]"
        bid = need(b, "id", str, w)
        if bid in board_ids:
            errs.append(f"{w}: duplicate board id '{bid}'")
        board_ids.add(bid)
        for k in ("owner", "repo", "projectId"):
            need(b, k, str, w)
        need(b, "projectNumber", int, w)
        if b.get("provider") != "github-project":
            errs.append(f"{w}.provider must be 'github-project'")
        fields = need(b, "fields", dict, w) or {}
        for fname in ("status", "priority"):
            f = need(fields, fname, dict, f"{w}.fields") or {}
            need(f, "fieldId", str, f"{w}.fields.{fname}")
            opts = need(f, "options", dict, f"{w}.fields.{fname}") or {}
            if not opts:
                errs.append(f"{w}.fields.{fname}.options is empty")
        flow = need(b, "statusFlow", list, w) or []
        sopts = fields.get("status", {}).get("options", {})
        for st in flow:
            if sopts and st not in sopts:
                errs.append(f"{w}.statusFlow: '{st}' has no matching status option id")
        for v in ("PVT_replace_me", "PVTSSF_replace_me"):
            if v in json.dumps(b):
                errs.append(f"{w}: still contains template placeholder '{v}' — run 'board.sh fields' and fill real ids")

    specs = need(cfg, "specs", list, "$") or []
    prefixes = set()
    for i, s in enumerate(specs):
        w = f"specs[{i}]"
        need(s, "id", str, w)
        pref = need(s, "taskPrefix", str, w)
        if pref in prefixes:
            errs.append(f"{w}: duplicate taskPrefix '{pref}' (must be unique across specs)")
        prefixes.add(pref)
        if pref and not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", pref):
            errs.append(f"{w}.taskPrefix '{pref}' must be alphanumeric starting with a letter")
        bref = need(s, "board", str, w)
        if bref and bref not in board_ids:
            errs.append(f"{w}.board '{bref}' does not match any boards[].id")
        need(s, "specPath", str, w)
        epics = need(s, "epics", list, w) or []
        epic_ids = set()
        for j, e in enumerate(epics):
            ew = f"{w}.epics[{j}]"
            eid = need(e, "id", str, ew)
            if eid in epic_ids:
                errs.append(f"{ew}: duplicate epic id '{eid}'")
            epic_ids.add(eid)
            ranges = need(e, "taskRanges", list, ew) or []
            for r in ranges:
                if not (isinstance(r, list) and len(r) == 2 and all(isinstance(x, int) for x in r) and r[0] <= r[1]):
                    errs.append(f"{ew}.taskRanges: {r!r} must be [lo, hi] ints with lo<=hi")
        for j, e in enumerate(epics):
            for g in e.get("blockedBy", []):
                if g.get("epic") not in epic_ids:
                    errs.append(f"{w}.epics[{j}].blockedBy: unknown epic '{g.get('epic')}'")
                board = next((b for b in boards if b.get("id") == s.get("board")), None)
                if board and g.get("untilStatus") not in (board.get("statusFlow") or []):
                    errs.append(f"{w}.epics[{j}].blockedBy: untilStatus '{g.get('untilStatus')}' not in statusFlow")
        # overlapping ranges within a spec
        seen = {}
        for e in epics:
            for lo, hi in (r for r in e.get("taskRanges", []) if isinstance(r, list) and len(r) == 2):
                for (olo, ohi), oid in seen.items():
                    if lo <= ohi and olo <= hi:
                        errs.append(f"{w}: epic '{e.get('id')}' range [{lo},{hi}] overlaps epic '{oid}' [{olo},{ohi}]")
                seen[(lo, hi)] = e.get("id")

    cmds = need(cfg, "commands", dict, "$") or {}
    need(cmds, "gate", str, "commands")

    if errs:
        print(f"INVALID: {len(errs)} problem(s) in {path}:")
        for e in errs:
            print(f"  - {e}")
        return 1

    print(f"VALID: {path}")
    print(f"  project: {proj.get('name')}  main={proj.get('mainBranch')}  branches={proj.get('branchPattern')}")
    for b in boards:
        print(f"  board '{b['id']}': {b['repo']} project #{b['projectNumber']}  flow: {' -> '.join(b['statusFlow'])}")
    for s in specs:
        seq = " -> ".join(e["id"] for e in s["epics"])
        print(f"  spec '{s['id']}' [{s['taskPrefix']}] on board '{s['board']}': {s['specPath']}  epics: {seq}")
    print(f"  gate: {cmds.get('gate')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ".claude/project.json"))
