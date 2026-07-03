---
name: board
description: Read and update the GitHub Project board configured in .claude/project.json. Use to find the next task, show a task with its human comments, move it between statuses, set priority/estimate, reply to comments, or file a bug. The board is the source of truth and must be kept up to date in real time.
---

# Board interaction

All board operations go through one script (never ad-hoc `gh project` calls — field ids live in `.claude/project.json`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" <subcommand>
```

## Subcommands
```
next [spec-id]              # prioritized + sequenced pick => "=> PICK: #N" (+ BLOCKED list)
show <issue#>               # title + body + ALL comments — always read comments: humans steer work there
move <issue#> "<status>"    # any name from the board's statusFlow
prio <issue#> <P0|P1|...>   # priority option name
est  <issue#> <points>
bug  "<title>" <prio> [<origin-issue#>]   # post-release bug -> first status (Backlog)
list ["<status>"]
comment <issue#>            # body on stdin: printf '%s' "text" | board.sh comment N
edit-body <issue#> <file>   # replace issue body (e.g. updated acceptance criteria)
fields                      # discover field/option ids (setup only)
config                      # validate project.json + print summary
```
Multiple boards: set `BOARD=<boards[].id>` env var; default is the first board in config.

## Rules (STRICT)
- Statuses follow the config's `statusFlow` in order (e.g. `Backlog → In progress → In review → QA → Ready → Deployed`). Never skip forward dishonestly: move to *In progress* when you start (≤ `methodology.maxInProgress` at once), to *In review* only when the gate command is green, later statuses only when merge/validation/publish actually happened.
- Once a task reaches a released status (Ready+), bugs against it are **new** items via `bug` — never reopen.
- **Human comments are directives.** Read them via `show` before acting on a task; reply via `comment`; if they change scope, update the issue body via `edit-body`.
- A fresh top-priority bug preempts feature work — re-run `next` at each iteration start.

## Requirement
`gh` needs the `project` scope: `gh auth status` must mention it, else run `gh auth refresh -h github.com -s project`.
