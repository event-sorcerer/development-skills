#!/usr/bin/env python3
"""audit.py — board.sh audit's reconciliation logic (issue #76).

Reconciles reality (local git + gh) against the board:
  (a) open PRs whose body lacks a board-issue reference (any bare #N — a
      lighter-weight bar than guard-pr-create.sh's Closes/Fixes/<slug>#N,
      since this is a backstop catching drift from BEFORE the guard was
      adopted or in a repo not running it, not re-enforcing the guard's
      stricter closing-keyword contract).
  (b) local branches matching project.branchPattern with no In-progress
      board item for the branch's embedded <id>.
  (c) In-progress board items with no matching local branch.
  (d) work.type: local ONLY — merged main-branch commits (the last
      COMMIT_SCAN_WINDOW of them; review round 1 — the window is printed
      unconditionally, discrepancy or not, so a clean report never implies
      the whole history was checked when it wasn't) whose subject lacks a
      #N reference, excluding a documented allowlist of recognized
      orchestrator process-commit classes (retro(, spec(, feedback(,
      config:). Those commits are exempt from (d) but always counted and
      enumerated in the report -- never silently hidden.

Prints one line per discrepancy plus a summary; exits 1 if any discrepancy
was found, 0 otherwise (a clean report).

Usage: audit.py <config-path> <board-id> <repo-root> <work-type> <prs-json-file>
Reads the project-items JSON ({"items":[...]}, from gh_project_items_json)
on stdin.
"""
import json
import os
import re
import subprocess
import sys

BARE_REF_RE = re.compile(r"#\d+")

# Recognized orchestrator process-commit classes (order = report order).
# Exempt from the (d) commit-subject scan, but always counted/enumerated.
PROCESS_PREFIXES = ("retro(", "spec(", "feedback(", "config:")

# (d)'s scan is capped, not exhaustive -- a repo with more history than this
# is silently under-scanned unless the cap itself is stated (review round
# 1). The note below is printed unconditionally in the work.type: local
# branch, discrepancy or not, so "AUDIT: clean" never implies "the whole
# history was checked" when it wasn't.
COMMIT_SCAN_WINDOW = 200


def has_ref(text):
    return bool(BARE_REF_RE.search(text or ""))


def branch_regex(pattern):
    r = re.escape(pattern)
    r = r.replace("<id>", r"(?P<id>\d+)").replace("<slug>", r"(?P<slug>[A-Za-z0-9._-]+)")
    return re.compile("^" + r + "$")


def local_branches(root):
    out = subprocess.run(
        ["git", "branch", "--format=%(refname:short)"],
        cwd=root, capture_output=True, text=True,
    ).stdout
    return [b.strip() for b in out.splitlines() if b.strip()]


def main():
    config_path, board_id, root, work_type, prs_path = sys.argv[1:6]
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import config as C

    cfg = C.load_config(path=config_path, warn=False) or {}
    project = cfg.get("project") or {}
    pattern = project.get("branchPattern")
    main_branch = project.get("mainBranch") or "main"

    items = (json.load(sys.stdin) or {}).get("items", [])
    in_progress = []
    for it in items:
        if (it.get("status") or "") == "In progress":
            num = (it.get("content") or {}).get("number")
            if num is not None:
                in_progress.append(num)

    try:
        with open(prs_path) as fh:
            prs = json.load(fh) or []
    except (OSError, ValueError):
        prs = []

    problems = []

    # (a) open PRs missing a board-issue reference
    pr_missing = [pr.get("number") for pr in prs if not has_ref(pr.get("body") or "")]
    if pr_missing:
        problems.append(
            "open PR(s) without a board-issue reference in the body: "
            + ", ".join("#" + str(n) for n in pr_missing)
        )

    # (b)/(c) branch <-> In-progress reconciliation (needs a branchPattern)
    if pattern:
        rx = branch_regex(pattern)
        branch_ids = {}
        for b in local_branches(root):
            m = rx.match(b)
            if m and "id" in m.groupdict():
                try:
                    branch_ids[int(m.group("id"))] = b
                except ValueError:
                    pass

        no_item = sorted(b for i, b in branch_ids.items() if i not in in_progress)
        if no_item:
            problems.append(
                "branch(es) matching branchPattern with no In-progress board item: "
                + ", ".join(no_item)
            )

        no_branch = sorted(i for i in in_progress if i not in branch_ids)
        if no_branch:
            problems.append(
                "In-progress board item(s) with no matching local branch: "
                + ", ".join("#" + str(i) for i in no_branch)
            )

    # (d) work.type: local ONLY -- merged main-commit-subject scan
    recognized_counts = {p: 0 for p in PROCESS_PREFIXES}
    if work_type == "local":
        log = subprocess.run(
            ["git", "log", main_branch, "--format=%H %s", "-n", str(COMMIT_SCAN_WINDOW)],
            cwd=root, capture_output=True, text=True,
        ).stdout
        commit_problems = []
        for line in log.splitlines():
            if not line.strip():
                continue
            sha, _, subject = line.partition(" ")
            matched_class = next((p for p in PROCESS_PREFIXES if subject.startswith(p)), None)
            if matched_class:
                recognized_counts[matched_class] += 1
                continue
            if not has_ref(subject):
                commit_problems.append(sha[:8] + " " + subject)
        if commit_problems:
            problems.append(
                "merged main commit(s) without a #N reference (local mode): "
                + "; ".join(commit_problems)
            )

    print("== board audit ==")
    for p in problems:
        print("DISCREPANCY: " + p)
    if work_type == "local":
        print(f"commit scan window: last {COMMIT_SCAN_WINDOW} commits")
        print(
            "recognized orchestrator process-commit classes: "
            + ", ".join(f"{p} ({recognized_counts[p]})" for p in PROCESS_PREFIXES)
        )
    if problems:
        print(f"AUDIT: {len(problems)} discrepancy class(es) found")
        sys.exit(1)
    print("AUDIT: clean")
    sys.exit(0)


main()
