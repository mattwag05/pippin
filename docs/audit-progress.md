# Audit progress

Running log for the mission in [MISSION.md](MISSION.md). Branch: `claude/pippin-apple-automation-3b11b3`. Nothing here is pushed.

## 2026-11-09

### Done

- Baseline: release build passes, 2,380 tests pass with 4 skipped. The 2 source warnings and 14 test-build warnings are fixed (commit `98531a9`).
- Wave 1: seven read-only audit lenses finished (security, reliability, data integrity, agent interface, performance, architecture, docs).
- Wave 2, skeptic: 54 P0 and P1 findings reviewed. 14 claimed P0s reduce to 3 P0 root causes and about 17 P1s. None was false, 16 were downgraded, 11 were duplicates.
- Beads: 26 issues filed under the label `audit-2026-11-09`. `pippin-lzuv` and `pippin-z84j` raised to P1.
- First P0 fixed: MCP tool calls validate arguments against the schema before running (commit `b97cd31`, test `NextStepTests.testToolsCallRejectsUnknownAndMistypedArguments`).
- Wave 3: competitive field and methodology committed before any result (commit `e7e0c12`), with the harness core.
- A disposable macOS 26.6.2 Tart VM (`pippin-bench`) is up with baseline Pippin 0.41.1 built inside it. Competitor tools run only there, never on the host.

### P0 root causes (open)

| Issue | Root cause |
| --- | --- |
| pippin-2cdf | `messages show` ignores the exclude list |
| pippin-psba | MCP child timeout is retryable for sends and writes, and an orphaned osascript survives the kill |
| pippin-t8iq | Calendar edit and delete on a recurring event have no occurrence identity |

### In flight when the usage limit stopped the run

- Red team: reproducing findings on throwaway objects only.
- Fix batch A (Messages: pippin-2cdf, pippin-uy77, pippin-7k69, pippin-lzuv), worktree branch `worktree-agent-acf2e6f381c1c45fd`. Stopped early.
- Fix batch B (runtime and MCP: pippin-psba, pippin-z84j, pippin-yswv, pippin-fy00, pippin-qpt5, pippin-zc0i, pippin-l4i8), worktree branch `worktree-agent-a9cf908baf2d7ca1b`. Stopped early.
- Fix batch C (Calendar, Notes, Memos: pippin-t8iq, pippin-78y5, pippin-lwci, pippin-cdv0, pippin-f8p6).
- Fix batch D (Mail and `do`: pippin-rcoa, pippin-h8ro, pippin-dqbz, pippin-x8wi, pippin-t4u0, pippin-qpt5, pippin-i114).
- Competitor install and adapters in the VM. Stopped early.
- Fixture seeding in the VM. Stopped early.

### Not started

- Merged audit report `docs/audit-2026-11-09.md` (waiting on the red team).
- Harness stages, baseline run, results.
- Wave 5 differentiators, Wave 6 re-run, Wave 7 docs.
