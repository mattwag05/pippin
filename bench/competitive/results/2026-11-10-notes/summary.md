# Notes re-run, 2026-11-10

A targeted re-run of the Notes speed stage after pippin-ai5s, with the same harness, fixture and method as [2026-11-09-final](../2026-11-09-final/summary.md): `harness/run.py --only pippin,sweetrb-notes --stages manifest,speed`, then `harness/checks.py --only pippin --stages correctness`. Pippin built from branch `claude/registry-generation` inside the `pippin-bench` VM (macOS 26.6.2, [environment.json](environment.json)). Only the two Notes tools were run; the other tools' results stand as published.

## Warm p50, ms (30 runs each)

| Operation | Pippin before | Pippin now | sweetrb-notes | Verdict under the tie rule (10 percent or 20 ms) |
| --- | --- | --- | --- | --- |
| notes.folders | 116.0 | 83.6 | 367.1 | Pippin leads |
| notes.list | 231.9 | 166.8 | 149.8 | tie (17.0 ms) |
| notes.search | 249.6 | 183.3 | 182.9 | tie (0.4 ms) |

Cold p50: folders 116.2 against 465.0, list 197.5 against 254.0, search 201.3 against 322.9; Pippin is faster on all three. Every Pippin run returned `ok` (30 of 30 per operation). Raw: [pippin.json](pippin.json), [sweetrb-notes.json](sweetrb-notes.json).

## Correctness

[pippin.checks.json](pippin.checks.json): all 10 checked operations `ok` with nothing missing, unexpected or duplicated.

## What changed

- Notes reads (`notes_list`, `notes_search`, `notes_show`, `notes_folders`) run inside the MCP server instead of a `pippin` child. The script still runs in an `osascript` child with its own hard kill.
- The list and search scripts make 7 Apple Events instead of 11: the folder filter is a `byName` specifier (no `whose` lookup), and no length reads. `NotesScriptBehaviorTests.testTheDefaultListMakesSevenAppleEvents` pins the count.
- Tried and dropped: a chained `notes.container.name` read, which would have saved two more events, returns nulls from Notes.
