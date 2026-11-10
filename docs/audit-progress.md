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
- Wave 5: safety gate merged ([safety-model.md](safety-model.md)): policy file, confirm tokens, rate limits, append-only action log, undo for edits, `dryRun` on every mutating tool, untrusted-content marking, `pippin undo`, `pippin log`, `pippin policy show`, and `mcp-server --apps`. Versioned JSON schemas in [schemas/v4/](schemas/v4) with golden and conformance tests. The CLI and MCP definitions are held together by drift tests, not generated from one source; that exception is documented in [architecture.md](architecture.md) (pippin-kkik).
- Wave 6: final head-to-head run from a fresh clone of commit `d91a21a` with one command ([results.md](competitive/results.md)). Pippin scores 4 on every scored axis and leads outright on Speed. It loses warm Notes list and search to sweetrb/apple-notes-mcp (pippin-ai5s), costs the most tokens per task when all tools are exposed (pippin-hd99), and had one injection trial flagged by the grader for quoting a marker (pippin-o072). Operability is not scored (pippin-0ifz).
- Wave 7: README, SECURITY.md (threat model), CONTRIBUTING.md, [architecture.md](architecture.md), [agent-integration.md](agent-integration.md), CHANGELOG and SKILL.md rewritten or updated. Every em and en dash removed from the Markdown docs.

### Still open

| Issue | Priority | Why it is deferred |
| --- | --- | --- |
| pippin-3ljg | P2 | Needs one live run against a scratch calendar and real Trash, which the VM fixture does not cover. |
| pippin-o190 | P2 | Argument edge cases (a positional that starts with `-`, `2.5` for an integer); schema validation already refuses most of them. |
| pippin-xr89 | P2 | Hardening bundle (notarization, file modes, argv secrets and others), each small and independent. |
| pippin-ai5s, pippin-hd99, pippin-o072, pippin-0ifz | P2, P3 | Competitive follow-ups from the results page. |
| pippin-kkik | P3 | Generating the registry from ArgumentParser needs its experimental dump-help format; drift tests hold the two together for now. |
| pippin-oqq9 | P3 | A CLI-mode child can outlive its deadline when a grandchild holds its output; the MCP path is not affected. |

### In flight (as of the first entry, now finished)

- Fix batch B (runtime and MCP), worktree branch `worktree-agent-a9cf908baf2d7ca1b`.
- Fix batch C (Calendar, Notes, Memos), worktree branch `worktree-agent-a1f593972d0afa777`.
- Baseline head-to-head run in the VM against Pippin 0.41.1.
- Fuzz, chaos and SBOM work in its own worktree.

### Not started (as of the first entry, now finished)

- Wave 5 safety model, action log and undo, schemas and conformance suite.
- Wave 6 re-run and `docs/competitive/results.md`. Wave 7 docs.
