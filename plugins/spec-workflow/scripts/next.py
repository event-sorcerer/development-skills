#!/usr/bin/env python3
"""next.py — pick the next task from board items, applying priority order, epic
sequencing, blockedBy guards, and the work-in-progress resume guard.

Usage: next.py <config-path> <board-id-or-empty> <item-list.json> [spec-id]
<item-list.json> is `gh project item-list --format json` output.
Prints candidates and either "=> PICK: #N" or "=> RESUME: #N" (WIP limit reached).
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as C  # noqa: E402


def main(cfg_path, bid, items_path, only_spec=""):
    cfg = C.load_config(path=cfg_path, warn=False)
    data = json.load(open(items_path))
    board = next((x for x in cfg["boards"] if x["id"] == bid), cfg["boards"][0])
    flow = board["statusFlow"]
    prios = list(board["fields"]["priority"]["options"])  # order = rank
    specs = [s for s in cfg["specs"] if s["board"] == board["id"] and (not only_spec or s["id"] == only_spec)]
    max_wip = cfg.get("methodology", {}).get("maxInProgress", 1)
    wip_status = flow[1] if len(flow) > 1 else flow[0]
    review_status = flow[2] if len(flow) > 2 else None
    serial_delivery = bool(cfg.get("methodology", {}).get("serialDelivery", False))

    def title_of(it):
        return it.get("title") or it.get("content", {}).get("title", "")

    wip = [it for it in data["items"] if it.get("status") == wip_status]
    review_wip = [it for it in data["items"] if review_status and it.get("status") == review_status]

    # #272 (review round 1 MUST FIX #1): serialDelivery is stricter than and
    # orthogonal to the maxInProgress resume guard below, but it must never
    # print WAIT while something is In progress — resuming/finishing that IS
    # the correct next action, and a WAIT with nothing In progress to work on
    # would deadlock the loop (a task can only leave In review by merging).
    # So: In progress present -> always RESUME (folded into the ordinary
    # resume guard below, which a bare serialDelivery now also triggers even
    # under maxInProgress); an In-review blocker with NOTHING In progress ->
    # WAIT, since only a merge can unblock it and there is nothing to resume.
    if serial_delivery and not wip and review_wip:
        for it in review_wip:
            num = it.get("content", {}).get("number")
            print(f'WAIT: serial delivery — #{num} {title_of(it)} is {it.get("status")}; merge it before picking')
        return

    def classify(title):
        """title -> (spec, epic, epic_rank, tasknum) or None for untagged (bugs)."""
        for s in specs:
            m = re.match(re.escape(s["taskPrefix"]) + r"-(\d+)", title)
            if not m:
                continue
            n = int(m.group(1))
            for rank, e in enumerate(s["epics"]):
                if any(lo <= n <= hi for lo, hi in e["taskRanges"]):
                    return s, e, rank, n
            return s, None, len(s["epics"]), n
        return None

    def at_least(status, wanted):
        try:
            return flow.index(status) >= flow.index(wanted)
        except ValueError:
            return False

    # resume guard: WIP at/over the configured limit -- or, under serialDelivery,
    # ANY WIP at all (#272 review round 1 MUST FIX #1) -- finish that work first.
    if len(wip) >= max_wip or (serial_delivery and wip):
        print(f"Work already {wip_status} (limit {max_wip}) — finish or move it before starting new work:")
        for it in wip:
            print(f'  #{it.get("content", {}).get("number")}  {title_of(it)}')
        print(f'\n=> RESUME: #{wip[0].get("content", {}).get("number")}  {title_of(wip[0])}')
        if serial_delivery and review_wip:
            for it in review_wip:
                num = it.get("content", {}).get("number")
                print(f'NOTE: serial delivery — #{num} {title_of(it)} is also In review; merge it too before picking new work.')
        return

    # epic completion map: (spec_id, epic_id) -> [statuses of its tasks]
    epic_status = {}
    for it in data["items"]:
        c = classify(title_of(it))
        if c and c[1] is not None:
            epic_status.setdefault((c[0]["id"], c[1]["id"]), []).append(it.get("status") or flow[0])

    def blocked(spec, epic):
        if epic is None:
            return None
        for g in epic.get("blockedBy", []):
            sts = epic_status.get((spec["id"], g["epic"]), [])
            if not sts:
                return f'epic {g["epic"]} unseeded — run seed-board'
            if not all(at_least(st, g["untilStatus"]) for st in sts):
                return f'epic {g["epic"]} not fully {g["untilStatus"]}'
        return None

    rows, held = [], []
    for it in data["items"]:
        if it.get("status") != flow[0]:
            continue  # Backlog only
        title = title_of(it)
        num = it.get("content", {}).get("number")
        pr = prios.index(it["priority"]) if it.get("priority") in prios else len(prios)
        c = classify(title)
        if c is None:  # untagged (bugs): priority decides, near front
            rows.append((pr, -1, 0, num, title))
            continue
        spec, epic, erank, n = c
        why = blocked(spec, epic)
        if why:
            held.append((num, title, why))
            continue
        rows.append((pr, erank, n, num, title))
    rows.sort()
    if not rows:
        print("(backlog empty" + (" or fully blocked)" if held else ")"))
    else:
        print("Next candidates (prioritized + sequenced):")
        for pr, _, _, num, title in rows[:5]:
            p = prios[pr] if pr < len(prios) else "P?"
            print(f"  #{num}  [{p}]  {title}")
        print(f"\n=> PICK: #{rows[0][3]}  {rows[0][4]}")
    for num, title, why in held[:5]:
        print(f"  BLOCKED #{num} {title}  ({why})")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
