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

### Later the same day

- Red team finished: 58 attacks, results merged into `docs/audit-2026-11-09.md` (commit `dfe3836`).
- Fix batch A (Messages) merged: commit `f9ebac8`. Closed pippin-2cdf, pippin-uy77, pippin-7k69. pippin-lzuv is fixed in code and stays open until it is verified on the fixture store.
- Fix batch D (Mail and `do`) merged: commit `0a04fdc`, 2,463 tests pass, lint clean. Closed pippin-rcoa, pippin-h8ro, pippin-dqbz, pippin-x8wi, pippin-t4u0, pippin-i114.
- Fixture state seeded in the VM and verified against `bench/competitive/fixtures/manifest.json` (commit `edc7691`).
- Harness: adapters for 12 tools, runner stages (manifest, speed, reliability, coverage), checks (correctness, safety, write probes), tripwire proxy, agent task runner and report generator.
- Methodology amendment 1 committed before any result (commit `3d3f553`).

### Waves 4 to 7 (2026-11-09 and 2026-11-10)

- Wave 4: every P0 and P1 is fixed and closed, including pippin-pvak and pippin-lzuv. Performance pass merged ([performance.md](performance.md)): Notes reads in bulk, Mail Envelope Index read-ahead, concurrent doctor, digest and status probes, and Messages reads in the MCP server process.
- Wave 5: safety gate merged ([safety-model.md](safety-model.md)): policy file, confirm tokens, rate limits, append-only action log, undo for edits, `dryRun` on every mutating tool, untrusted-content marking, `pippin undo`, `pippin log`, `pippin policy show`, and `mcp-server --apps`. Versioned JSON schemas in [schemas/v4/](schemas/v4) with golden and conformance tests. The MCP registry is generated from the ArgumentParser definitions, so the CLI and MCP share one source ([architecture.md](architecture.md), pippin-kkik).
- Wave 6: final head-to-head run from a fresh clone of commit `d91a21a` with one command ([results.md](competitive/results.md)). Pippin scores 4 on every scored axis and leads outright on Speed. It loses warm Notes list and search to sweetrb/apple-notes-mcp (pippin-ai5s), costs the most tokens per task when all tools are exposed (pippin-hd99), and had one injection trial flagged by the grader for quoting a marker (pippin-o072). Operability is not scored (pippin-0ifz).
- Wave 7 follow-up (2026-11-10): the MCP registry is generated from the CLI (pippin-kkik); Notes reads run in the server, which ties sweetrb/apple-notes-mcp warm (pippin-ai5s); doctor passes on the clean VM; a live test validates every read tool against the schemas; Operability is scored, Pippin 4 (pippin-0ifz); and with grader 2 the agent tasks are 9 of 9 for Pippin in both modes (pippin-o072). Mail and Voice Memos are measured under Amendment 4: Pippin scores 4 on every axis except Speed, where the primary run ties it at the top with 3 after losing three warm Mail reads. Mail reads then moved into the server and `mail accounts` reads names only (pippin-k177); the Mail re-run has no warm losses and Speed scores 4. See [results.md](competitive/results.md).
- Wave 7: README, SECURITY.md (threat model), CONTRIBUTING.md, [architecture.md](architecture.md), [agent-integration.md](agent-integration.md), CHANGELOG and SKILL.md rewritten or updated. Every em and en dash removed from the Markdown docs.

### Still open (as of 2026-11-10, now closed or split: see the next section)

| Issue | Priority | Why it is deferred |
| --- | --- | --- |
| pippin-3ljg | P2 | Needs one live run against a scratch calendar and real Trash, which the VM fixture does not cover. |
| pippin-o190 | P2 | Argument edge cases (a positional that starts with `-`, `2.5` for an integer); schema validation already refuses most of them. |
| pippin-xr89 | P2 | Hardening bundle (notarization, file modes, argv secrets and others), each small and independent. |
| pippin-ai5s, pippin-hd99, pippin-o072, pippin-0ifz | P2, P3 | Competitive follow-ups from the results page. |
| pippin-oqq9 | P3 | A CLI-mode child can outlive its deadline when a grandchild holds its output; the MCP path is not affected. |

### Follow-up sweep (2026-11-10, branch `claude/beads-sweep`)

- pippin-o190, pippin-oqq9, pippin-qq4c, pippin-p813 and pippin-lb1i are closed. Two of the three o190 parts and all of lb1i were already fixed; bare `pippin` trapping was the remaining bug.
- pippin-xr89: script bodies off argv, owner-only file modes, stderr no longer a failure signal, `fields` on `messages search`, a keyset cursor for `mail list` on the Envelope Index path, the Reminders timeout race, fail-closed lints, and hardened-runtime signing. The disclaim `waitpid` was already robust. Keyset cursors then followed for `memos list`, `reminders list`, `calendar events` and `upcoming`, the action log and `mail list` on the metadata store and JXA fallback paths, `notes list`, `contacts search` and `mail search` on the Envelope Index and metadata store paths and with `--semantic` (pippin-hzuw). Split out: notarization (needs credentials), and keyset paging for `mail search` on the JXA path.
- pippin-hd99: the default tool list went from 22,617 to 21,829 harness tokens. Most of the rest is JSON structure for 79 tools and about 420 parameters, so a larger cut needs a smaller default tool set, which is a contract decision and is filed separately.
- pippin-3ljg live run, in the `pippin-bench` VM (macOS 26.6.2) on the fixture calendar and Voice Memos store, never on real data:
  - Pippin 1.0.0, "Weekly Sync" (five weekly occurrences, one id). Edit with `--occurrence 2027-03-01T14:30:00Z --title` renamed only the third occurrence, which then carries its own id. Delete with `--occurrence 2027-02-22` removed only the second. Delete with `--span all` removed the rest, the detached third occurrence included.
  - `memos delete` on Pippin 1.0.0 failed on the fixture recording tried: `no such function: NSCoreDataDATriggerUpdatedAffectedObjectValue`. The store's delete trigger runs for a recording that is in a folder. The audio was moved back and the row kept, as designed. With the fix on this branch the audio is in `~/.Trash`, the row is gone and the other 11 recordings are listed.
  - The hardened Developer ID build ran there with Calendar, Reminders and Voice Memos access.
  - Followed up the same day: `occurrence_required` exits 2, shipped as a bug fix by Matt's decision although [contract.md](contract.md) lists exit-code remaps as breaking (pippin-4zv1), and the Notes "Recently Deleted" check matches the name Notes shows in the system language as well as the English one (pippin-nrrx).

### In flight (as of the first entry, now finished)

- Fix batch B (runtime and MCP), worktree branch `worktree-agent-a9cf908baf2d7ca1b`.
- Fix batch C (Calendar, Notes, Memos), worktree branch `worktree-agent-a1f593972d0afa777`.
- Baseline head-to-head run in the VM against Pippin 0.41.1.
- Fuzz, chaos and SBOM work in its own worktree.

### Not started (as of the first entry, now finished)

- Wave 5 safety model, action log and undo, schemas and conformance suite.
- Wave 6 re-run and `docs/competitive/results.md`. Wave 7 docs.
