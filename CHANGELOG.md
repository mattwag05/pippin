# Changelog

All notable changes to pippin are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added

- [feat] Messages and Mail now tie senders to Apple Contacts automatically. `messages list/show/search` populate `from_display_name` and participant `display_name` from Contacts (a 1:1 thread now shows the contact's name instead of a bare phone number), and `mail list/search/activity/show` add a `fromContact` field with the sender's Contacts name. Resolution uses a one-pass Contacts reverse index (phone numbers normalized to digits + last-10 so E.164 handles match free-form stored numbers; emails matched case-insensitively, unwrapping `Name <addr>` headers). Best-effort: silently skipped when Contacts isn't authorized, never prompting or failing the command. Opt out per command with `--no-contacts`. Closes pippin-2nv.

### Changed

- [build] `make install` now removes the target binary before copying. Overwriting a signed binary in place reused its inode and left macOS AMFI's cached code signature stale, SIGKILLing the next launch ("Killed: 9") despite an on-disk-valid signature; a fresh inode avoids it.

### Fixed

- [bug] `messages show`/`messages search` now return message body text. Modern macOS leaves the `message.text` column NULL and stores the body in `attributedBody` as a typedstream (NSArchiver) blob, which pippin wasn't decoding — so `messages show` returned metadata with no text and `search` couldn't match recent messages. pippin now decodes `attributedBody` (via `NSUnarchiver` in a crash-safe ObjC shim) when `text` is empty, and `search` decode-scans recent attributedBody-only messages. Conversation last-message previews are decoded too. Closes pippin-cc1.

## [0.31.0] - 2026-06-09

### Changed

- [feat] **pippin now runs as its own macOS TCC "responsible process."** At startup it re-execs itself disclaimed (via `responsibility_spawnattrs_setdisclaim`), so Reminders/Calendar/Contacts/Automation consent keys on pippin's own signed identity instead of whichever app launched it (Terminal, Codex, the [agent-runtime] gateway, launchd). This fixes agent/background callers being denied even though the same binary worked from a terminal: grant pippin **once** (interactively, `pippin permissions`) and it works under every launcher. **One-time migration:** because grants now attach to pippin's identity, existing permissions must be re-granted once after upgrading — run `pippin permissions` from a terminal and approve the prompts. Opt out with `PIPPIN_NO_DISCLAIM=1`. Closes pippin-0vr.

### Fixed

- [bug] Reminders/Calendar commands no longer hang when access is `not_determined` in a non-interactive/background context: pippin only blocks on the TCC prompt when a user can actually answer it (interactive TTY, not MCP), otherwise it fails fast with `access_denied` + remediation. (pippin-0vr)

## [0.30.0] - 2026-06-08

### Added

- [feat] `--fields` is now a universal option on every structured command. It was lifted into the shared output option group, so commands that previously lacked field projection — **`mail search`**, **`mail activity`**, and **`calendar search`** — now support `--fields` for projecting JSON/agent output to just the requested keys (e.g. `pippin mail search invoice --fields id,subject --format agent`). Existing per-command `--fields` behavior and output formatting are unchanged. Closes pippin-yux.

### Changed

- [refactor] Audio and browser bridges no longer hand-roll the `temporaryDirectory + UUID + defer cleanup` pattern; temp-file lifetime now lives in a shared `withTemporaryFile`/`temporaryFileURL` helper. No user-visible behavior change. Closes pippin-u39.

### Fixed

- [perf] `pippin status` no longer times out on multi-account setups. The dashboard's seven sections (Mail, Calendar, Reminders, Voice Memos, Notes, Contacts, Permissions) were gathered sequentially with no overall deadline, so their times summed — on a multi-account Mail setup the N+1 mailbox enumeration alone could push the total past the 60s MCP `runChild` cap and the whole call was SIGKILLed (works fine with narrow queries). The sections now run concurrently (total cost ≈ the single slowest section) under a wall-clock budget (50s under MCP, unbounded in CLI); a section that exceeds the budget is dropped to `nil` and the report's new top-level `timedOut` flag marks the dashboard partial instead of returning nothing. Closes pippin-0nk.

## [0.29.0] - 2026-06-08

### Added

- [build] Stable-identity code signing so macOS TCC permission grants persist across rebuilds/upgrades. SwiftPM ad-hoc/linker-signs by default — the code identity is the CDHash, which changes every build, so TCC orphaned the prior grant on every `make install` / `brew upgrade` (and the two install paths got separate grants). `make install`/`make release` and the Homebrew formula now run `scripts/sign.sh`, which signs with a Developer ID Application identity + a fixed `com.mattwag05.pippin` identifier (guarded: ad-hoc fallback when no identity is present, so CI/other machines still build). `pippin doctor` gained a **Code signing** row reporting whether grants will persist. Notarization is not required for TCC (only for distributing downloaded binaries to other Macs; `PIPPIN_SIGN_HARDENED=1` enables it). Closes pippin-xzu.
- [feat] New `pippin permissions` command + proactive permission priming during `pippin init`, so each app integration's macOS privacy permission is resolved once (interactively) instead of being deferred to "first use" — which silently fails when first use is a background agent (e.g. the [agent-runtime]/[agent] LaunchAgent) that can't show a TCC dialog. Run interactively, `pippin permissions` triggers each promptable prompt up front (EventKit Reminders/Calendar, Contacts, and the Mail/Notes Automation prompt), then reports the status of all seven integrations including the two Full Disk Access ones (Voice Memos, Messages) that have no prompt and must be granted manually. Priming is automatically skipped when nothing can answer a dialog — under MCP, `--format agent|json`, a non-TTY pipe, or `--status` — where it's a pure read-only report (`[{integration, mechanism, state, promptable, detail, remediation?}]`). Re-runnable any time (e.g. after a macOS upgrade or reinstall resets TCC). Closes pippin-uu3, pippin-dkf.
- [build] The pippin binary now embeds an Info.plist (`__TEXT,__info_plist`) with the EventKit/Contacts/AppleEvents usage-description strings and a stable bundle identifier. Without these, `requestFullAccess*` is unreliable (or crashes) outside an interactive terminal — the root cause behind background launches hitting unexpected/silent permission failures. Closes pippin-1zv.

### Fixed

- [bug] `pippin doctor` now checks **Messages** (Full Disk Access) access, which was previously uncovered, and the Calendar/Reminders/Contacts "not determined" rows now point at `pippin permissions` (the interactive grant) with full remediation instead of the misleading "grant on first use" — which is exactly the path that silently fails for background agents. Closes pippin-0jx.

- [bug] The Reminders/Calendar/Contacts permission remediation fix above now also applies in **human (non-agent) CLI mode**, not just `--format agent`. The interactive error path resolved its hint via the code-only catalog lookup, so `pippin reminders create …` with denied access still printed the Voice Memos "Full Disk Access" guidance under the (correct) Reminders error header. Agent and human paths now share one `RemediationCatalog.resolve(for:)` resolver — a regression test asserts they can't diverge again. Closes pippin-oxy.
- [bug] Foreign/bridged errors (`NSError`, `URLError`, `CocoaError`) that reach the agent-mode envelope no longer emit a junk `error.code`. The code was derived by snake-casing `String(describing: error)`, which for these turns the whole error *sentence* into a per-instance string like `error _domain=_n_s_u_r_l_error_domain _code=-1001 "…"` in a field agents/MCP clients branch on. Such errors now collapse to a stable, classifiable `unknown_error` (exit code 5), while the human-readable detail is preserved in `error.message`. Typed pippin error codes are unchanged. Closes pippin-2tg.
- [bug] Permission-denied errors for **Reminders**, **Calendar**, and **Contacts** now return the correct fix-it guidance. All three (and Voice Memos) derive the same agent error code `access_denied`, and the structured `remediation.human_hint` was looked up purely by that code — so a Reminders/Calendar/Contacts permission failure (e.g. an MCP `reminders_create` call from a background agent) was told to "grant **Full Disk Access** for **Voice Memos**", the wrong System Settings pane and wrong permission entirely. Each error now carries its own permission-specific remediation pointing at the right pane (Privacy & Security > Reminders/Calendars/Contacts), explaining that the grant attaches to the launching app (terminal or MCP/agent client) rather than the pippin binary, and noting that a background agent that can't show the first-use prompt should run `pippin <area> list` once interactively. The `access_denied` code is unchanged, so exit-code classification and MCP branching are unaffected. The `doctor` Calendar/Reminders/Contacts hints were updated to match. Closes pippin-ci2.

## [0.28.0] - 2026-06-03

### Added

- [feat] Calendar date options now accept a **space** between date and time, not just strict `T`-separated ISO 8601. `calendar create --start '2026-06-04 14:30'` (and `--end`, plus `agenda`/`list`'s `--from`/`--to`) parse the natural `'YYYY-MM-DD HH:MM'` / `'YYYY-MM-DD HH:MM:SS'` forms agents and humans reach for, interpreting them at local time — the same instant as the `T`-separated form. Minute-precision `T` forms (`2026-06-04T14:30`, previously rejected for lacking seconds) now parse too. Strict ISO stays canonical; date-only and timezone-qualified inputs are unchanged. Closes pippin-3gp.

### Changed

- [refactor] `AudioBridge.STTEntry` now carries its mlx-audio argument contract as a typed `STTContract` (`.generate`/`.legacy`) enum, set once by `resolveSTTEntry` where the entry point is chosen. `buildSTTArgs`/`transcribe` branch on `entry.contract` instead of re-deriving it by string-matching the executable path and prefix args at each call site — removing the duplicated string-match and making a future third contract a compile-checked change. No behavior change. Closes pippin-dzf.
- [build] `doctor`'s mlx-audio probe now validates the STT CLI's argument contract, not just that it's importable and responds to `--help`. It captures `mlx_audio.stt.generate --help` and asserts every flag pippin will actually pass (`--model`, `--audio`, `--output-path`, `--format`) is advertised, failing with a named-flag remediation when one is missing. Previously the probe only checked `--help` exit 0, so a version skew that renamed or dropped a required flag (the class of break behind pippin-8ik) reported all-green while `memos transcribe`/`summarize`/`capture` failed. The expected-flag list is derived from the same `buildSTTArgs` the real invocation uses, so the probe and the call path can't drift. Closes pippin-xua.

### Fixed

- [bug] In `--format agent` mode, argument validation and parse failures (a malformed `--start`, a missing required flag, an unknown flag) now exit `2` (usage / bad input) instead of `5` (tool/bridge failure), so an agent branching on the exit class can tell "fix my arguments and retry" apart from "the tool broke." Outside agent mode, ArgumentParser keeps its own `64` so its formatted usage help is preserved. Closes pippin-3sy.
- [bug] `--format agent` (and therefore every MCP tool call) now surfaces ArgumentParser validation messages instead of an opaque envelope. A malformed flag like `calendar create --start "2026-06-04 12:00"` returned `error.message: "The operation couldn’t be completed. (ArgumentParser.CommandError error 1.)"` in agent mode while default (human) mode showed the actionable "`--start must be in YYYY-MM-DD or ISO 8601 format.`" The agent error path now recovers ArgumentParser's real text via the root command's `message(for:)`, so agents/MCP clients get the same guidance humans do (covers validation errors, missing required args, and unknown flags). Closes pippin-kzi.
- [bug] `notes list` / `notes search` no longer return zero results on large Notes libraries. The newest-first sort materialized each note's `modificationDate` with one Apple Event *per note* — O(n) round-trips that, on a big vault, spent the entire 22s soft-timeout before the sort, so the page came back empty (only `--folder <name>` worked, because that collection was small enough to scan in time). The dates are now bulk-fetched off the collection specifier in a single Apple Event, so the sort loop fires zero Apple Events and the default listing returns a non-empty newest-first prefix that agents can chain `notes show` from. Closes pippin-mo7.

## [0.27.0] - 2026-06-03

### Added

- [feat] Configurable OpenAI-compatible AI backend. A new `openai` provider talks to any OpenAI-compatible Chat Completions endpoint (`POST {baseURL}/chat/completions`) — OpenAI, OpenRouter, a homelab gateway (e.g. Manifest), [local-llm], vLLM, LM Studio, llama.cpp's server, or Ollama's own `/v1` shim. Configure via `ai.provider: "openai"` + `ai.openai.{baseURL, model, apiKey}` in `~/.config/pippin/config.json`, or per-command with `--provider openai --model <m> --api-key <k>`. The API key is optional (local endpoints that don't authenticate send no `Authorization` header). Lets `memos summarize`/`capture`, `calendar`/`reminders smart-create`, `actions`, `do`, and `mail --ai-assisted` run against any reachable model server instead of being tied to local Ollama. (Mail semantic-search embeddings remain Ollama-only.)

## [0.26.0] - 2026-06-03

### Fixed

- [bug] Voice Memos transcription now works with mlx-audio 0.4.2. `memos transcribe`, `memos summarize`, and `memos capture` previously failed with an opaque `mlx_audio.stt.generate` usage error: pippin passed the pre-0.4.2 CLI shape (positional audio file, `--format text`, short model alias) but 0.4.2 requires a named `--audio` flag, a `--output-path` (the transcript is written there, not to stdout), `--format json`, and a full Hugging Face model id. pippin now builds the correct 0.4.2 argument vector, maps the `parakeet` alias to `mlx-community/parakeet-tdt-0.6b-v2`, reads the transcript from the output file, and treats a missing/empty output file as failure (0.4.2 exits 0 even on error). The legacy `mlx_audio.stt` path is preserved for pre-0.4.2 installs. Closes pippin-8ik.

### Added

- [feat] `mail list --preview N` now reads/writes through the local mail body cache (the same `~/.config/pippin/mail-cache.db` used by `mail show`/`mail index`). Previews are assembled in two passes — a cheap metadata-only enumeration, then a single batch osascript that fetches bodies only for cache misses and writes them through. A warm cache skips the expensive per-message `msg.content()` IMAP download entirely; a cold cache adds just one extra metadata pass. Read/unread and all other metadata stay live (only the body preview comes from the cache). Always-on; new `mail list --no-cache` forces live fetches. Closes pippin-8fq. (`mail search --body` remains deferred — tracked as pippin-1wy.)

## [0.25.0] - 2026-06-03

### Added

- [feat] Local mail body cache. `mail show` and `mail index` now read message bodies through a SQLite cache (`~/.config/pippin/mail-cache.db`) keyed by compound id, so the expensive per-message `msg.content()` IMAP download happens once. Repeat reads are ~75× faster (≈1.3s → ≈17ms in local testing) and `mail index` re-runs skip already-fetched bodies. New `mail cache stats|clear|warm` subcommands (`warm` pre-fetches recent bodies; `clear --older-than-days N` prunes) and a `mail show --no-cache` escape hatch. Read/unread state is never cached — `mail list`/`search` stay live. Closes pippin-e6m. (The bulk `list --preview` / `search --body` timeout path fetches bodies inside the JXA loop and needs a separate restructure — tracked as a follow-up.)
- [feat] `mail list` now accepts `--fields` (and the `mail_list` MCP tool a `fields` arg) to project the output to chosen JSON keys, trimming agent token usage. Closes pippin-1k0.
- [feat] `pippin agent-info` — a capability-probe command for orchestrating agents. One call returns pippin's contract as structured data (envelope v1): version, `schema_version`, output `formats`, the typed `exit_codes` map, `global_flags`, experimental-gate status, MCP `tool_count` (sourced from the tool registry so it can't drift from `mcp-server --list-tools`), and the visible top-level `commands`. Complements `mcp-server --list-tools`. Closes pippin-zgs.
- [feat] Typed process exit codes. On failure `pippin` now sets a distinct exit code derived from the envelope's `error.code` so a calling shell or agent can branch on the failure *class* without parsing JSON: `3` not-found, `4` auth/permission/config, `5` tool/bridge failure (default), `7` timeout/rate-limit, `2` usage/bad-input. Argument-parsing failures keep ArgumentParser's `64`. Applies in `--format agent` mode and to catalogued errors in text/json mode; the MCP server passes the code through verbatim. Documented in SKILL.md and docs/mcp-server.md. Closes pippin-y7y.

### Fixed

- [bug] `--fields` projection now works in `--format agent`, not just `--format json`. It was previously silent in agent mode — the exact format AI agents/MCP clients use — so `notes`/`calendar`/`reminders` list/search calls returned full objects despite `--fields`. Projection now applies inside the envelope's `data` (leaving `v`/`status`/`duration_ms`/`warnings` intact) and preserves `next_cursor` on paginated output. The three duplicated field-filter implementations (ReminderModels/CalendarModels `jsonData`, NotesCommand `filteredNoteDicts`) were consolidated onto one shared `FieldProjection` helper so json- and agent-mode stay in lockstep. Closes pippin-1k0.

## [0.24.3] - 2026-06-03

### Added

- [feat] `reminders list` and `reminders search` now surface a partial-results advisory when the underlying EventKit fetch hits its 15s wall-clock cap (store hang / permission edge). Previously the timeout signal was discarded after a lone stderr line; MCP/agent clients now get a structured `warnings` entry in the envelope (and JSON/text parity), mirroring the Mail/Contacts soft-timeout pattern. `reminders` is also reflected in the `digest` reminders-section warnings. Lighter, ship-now alternative to the still-deferred generic async-timeout helper (pippin-91n). Closes pippin-w3y.

### Changed

- [ci] Bump Node-20 GitHub/Forgejo actions to their Node-24 releases ahead of GitHub's 2026-06-16 forced-migration / 2026-09-16 removal deadline: `actions/checkout` v4→v5.0.1, `softprops/action-gh-release` v2.5.0→v3.0.0, `actions/cache` v4.3.0→v5.0.5 (all re-pinned to full SHAs). `maxim-lobanov/setup-xcode` v1.7.0 and `github/codeql-action` v4.35.3 already run on Node 24, so they're unchanged. Closes pippin-e3x.

## [0.24.2] - 2026-06-02

### Fixed

- [bug] Make `JobStoreTests.testJobIdGeneratesUniqueValues` deterministic. It generated 100 job IDs within a single millisecond and asserted uniqueness on the 20-bit random suffix, flaking ~0.5% of runs on a birthday collision. The test now spaces generations past the 1 ms boundary (exercising the timestamp prefix that makes real spawns unique) and adds a constant-suffix guard. No change to `JobId.generate()`. Closes pippin-84q.

## [0.24.1] - 2026-06-02

### Documentation

- [docs] Refresh `SKILL.md` to current state: bump to 0.24.0, document the `messages`, `digest`, `actions`, `job`, `do`, `batch`, and `mcp-server` command groups, mark `audio`/`browser` as experimental (`PIPPIN_EXPERIMENTAL=1`), fix `completions` to positional-arg syntax, and replace the pre-envelope agent-output examples with envelope v1 + pagination guidance.
- [docs] Add a graphify knowledge graph under `graphify-out/` for repo onboarding and register `/graphify` for Claude Code, Codex, OpenCode, Pi, [agent-runtime], and [agent-cli].
- [docs] Repo-wide doc drift sweep: fix `reminders list`/`create` (`--list` takes an ID, title is positional) and `calendar events --calendar-name` examples in `README.md`; rewrite the stale `.github/copilot-instructions.md` (was v0.1.0 / 5 subcommands / wrong deps); remove the dead SwiftLint section and correct the `.forgejo` "retired" note in `docs/gotchas/build.md`; fix the release skill's "wait for CI" step (GitHub CI is disabled — gate is local `make ci`); correct the `gastownhall/beads` URL and CHANGELOG pointer in `docs/ROADMAP.md`; fix the single-account `--body` search timeout (75s) and add the MCP-clamp note in `TIMEOUT_ANALYSIS.md`; de-hardcode stale test counts.
- [docs] Reduce `AGENTS.md` to a thin pointer to `CLAUDE.md` (the single source of truth).
- [build] Untrack the stray repo-root `issues.jsonl` (accidental early commit; gitignored, no longer regenerated since `export.auto: false`).
- [ci] Bring the Forgejo workflows into parity with GitHub: add the detach-blocking lint to `.forgejo/workflows/ci.yaml`, and fix `release.yaml` to use the self-hosted `macos` runner label (was `macos-15`) with a SHA-pinned checkout.
- [ci] Remove the GitHub Copilot automatic CI-troubleshooting workflow (`.github/workflows/copilot-ci-fix.yml`) — no longer in use — and strip its references from `CLAUDE.md` / `copilot-instructions.md`. The Copilot coding agent (manual `@copilot`) and its `copilot-setup-steps.yml` env remain.

## [0.24.0] - 2026-06-02

### Added

- [feat] `detachBlocking` helper (`pippin/DetachBlocking.swift`) — single-purpose wrapper that hops sync, thread-blocking work to a detached `Task` so async commands no longer stall the cooperative pool when invoking subprocess waits, `DispatchSemaphore.wait`, or `sendSynchronousRequest`. Throwing and non-throwing overloads. Documented at `docs/gotchas/swift.md` § Cooperative-thread blocking.
- [feat] `pippin doctor --latency` — opt-in Mail bridge latency probes (list/activity/search) with classifyLatency thresholds (<20s ok, 20–55s warn, ≥55s fail with remediation hint). Self-bounded inside the bridge (softTimeoutMs=20000) so the whole `--latency` pass is bounded around 60s. Closes pippin-11e.
- [feat] `pippin doctor` — Ollama check now also verifies the configured model is actually pulled (`/api/tags` lookup with base-name fuzzy match). When missing, the failure detail names the model and the remediation lists `ollama pull <model>` plus a sample of what's available so the user can pick. Closes pippin-n5p.
- [feat] `NotesBridge.countNotes(folder:)` — single-Apple-Event count helper for dashboards/digests that need `noteCount` without iterating bodies. Adopted by `StatusCommand.gatherNotesStatus`. Closes pippin-9s6.
- [feat] `BatchBudget` (`pippin/BatchBudget.swift`) — wall-clock budget for parallel batch operations. `forCurrentContext()` picks 50s under MCP (PIPPIN_MCP=1) and unlimited in CLI. Wired into `memos export --all --transcribe` and `memos transcribe --all` so MCP clients see a partial-results warning instead of mid-batch SIGKILL. Closes pippin-55e.
- [feat] `pippin/AIProvider/AIProvider.swift` — `isMCPContext()` / `aiRequestTimeoutSeconds()` helpers. `OllamaProvider` runs a 2s `GET /api/version` preflight before completion calls; failures surface as new `AIProviderError.providerUnreachable` with a "start it with `ollama serve`" hint. Both providers shorten the request budget to 50s under MCP (vs 120s CLI) so the JSON-RPC client sees a typed AI error rather than the runChild SIGKILL. Closes pippin-5et.
- [feat] `MCPServerRuntime.runChild` sets `PIPPIN_MCP=1` in child env so AI providers and `BatchBudget` can detect MCP context.
- [feat] `StatusReport.NotesStatus.timedOut` — new optional field (defaults to false; backward-compat init) populated from `listFolders` + `listNotes` outcomes. Text mode appends "(partial — Notes scan timed out)". Closes pippin-53p.
- [feat] `pippin notes list` native offset pushdown for deep pagination — `buildListScript`/`listNotes` take an `offset` so `--page-size`/`--cursor` walks past the old 500-note ceiling without re-fetching from the top (mirrors the MailCommand pushdown path). Closes pippin-m3y.
- [feat] `pippin doctor --latency` fourth probe — a Mail.app ready-poll latency probe (`MailBridge.probeReady()`, runs `jsMailReadyPoll` only, no mailbox scan) wired as the first probe, so a slow Mail.app startup/sync is distinguishable from a slow query. Closes pippin-11e.
- [test] 26 new tests across `DetachBlocking`, `BatchBudget`, `DoctorTests` (latency classifier + Ollama model matcher), `AIProviderTests` (preflight + MCP context), `NotesBridgeSoftTimeoutTests` (pre-sort budget check + countNotes script shape), `StatusCommandTests` (Notes timedOut Codable). DoctorTests caches `runAllChecks()` once per suite — full suite wall time 22s → 19s. Test count 1632 → 1658.

### Fixed

- [bug] Async commands no longer stall the Swift 6 cooperative thread pool. Wrapped sync blocking work in `detachBlocking` at the async boundary across DoctorCommand, InitCommand, AudioCommand (4 sites), MailCommand semantic-search paths, StatusCommand, BrowserCommand (8 sites) + BrowserRetry, SummarizeCommand, MemosCaptureCommand, ActionsCommand, CalendarCommand smart-create + briefing, RemindersCommand smart-create, MailCommand list --summarize / show --sanitize. Closes pippin-3re, pippin-f1n, pippin-ka7, pippin-zwn, pippin-8l6.
- [bug] `NotesBridge.buildListScript` / `buildSearchScript` — large vaults could spend the entire 22s soft-cap budget on `app.notes()` and the modificationDate-comparing sort alone, busting the ScriptRunner 30s hard cap before the loop ran. Now skips the sort when over budget and emits unsorted notes (capped to limit) with `timedOut=true`. ScriptRunner default 30→35s on read-only Notes paths. Closes pippin-4as.
- [bug] `AudioConverter.swift` — silenced Swift 6.3 Sendable warnings via `@preconcurrency import AVFoundation` and `nonisolated(unsafe) var fed` (the converter callback runs synchronously). Closes pippin-srt.
- [bug] `runConcurrently<Input, Output>` now requires `Input: Sendable, Output: Sendable` so the `@Sendable` closure capture is well-typed. All callers already pass Sendable types. Closes pippin-69y.
- [bug] `MailBridge.timedOut` and `NotesBridge.timedOut` no longer silently dropped by callers that need the signal. `DigestCommand` notes section + `MailAICommand` index/triage + `StatusReport.NotesStatus` now surface partial-results warnings. Closes pippin-6tg, pippin-53p.
- [bug] `MessagesCommand.swift` — removed five `try?` wrappers around the non-throwing `MessagesAuditLog.record`. Adjacent `StatusCommand.swift` cleanup: dropped dead `?? ""` on non-optional `account.email`, replaced four deprecated `EKAuthorizationStatus.authorized` comparisons with `.fullAccess` (we target macOS 15+). Closes pippin-7xn.
- [perf] `pippin status` no longer hangs ~84s on Notes count — `gatherNotesStatus` switched from `listNotes(limit: 500)` (which iterates every note's body+plainText) to the new `NotesBridge.countNotes()` single Apple Event. End-to-end status duration on a 440-note vault: 84s → 12.8s. Closes pippin-9s6.
- [bug] `parseRange("today+N")` (calendar `--range`) and `MessagesDatabase.appleNanos` no longer crash on out-of-range input. `today+<huge N>` overflow-trapped on `n + 1` and force-unwrapped `Calendar.date(byAdding:)`; `appleNanos` trapped on `Int64(Double)` for far-future dates. Now caps N at ~10 years with guard-lets, and clamps the nanosecond value to Int64 bounds. Closes pippin-dr7.
- [bug] Voice Memos with NULL Core Data columns no longer crash `memos list`/`getMemo`. `VoiceMemo.init(row:)` force-decoded `ZUNIQUEID`/`ZDURATION`/`ZDATE`/`ZPATH`, and GRDB traps on a NULL — common for an iCloud recording not yet downloaded. Now decodes optionally with fallbacks. `deleteMemo` also force-decoded `ZPATH` and an empty path would have made `appendingPathComponent("")` target (and delete) the whole recordings directory — guarded. Closes pippin-hgo.
- [bug] `OllamaEmbeddingProvider` (semantic search / triage) now honors MCP timeout budgets. It hardcoded 120s/300s and ignored `isMCPContext()`, so under `PIPPIN_MCP=1` a slow embedding server blew past the 60s child cap and was SIGKILLed (misreported as a protocol error). New `requestTimeout(batch:)` clamps to the MCP-aware budget (50s) under MCP, keeping the generous CLI budget otherwise. Closes pippin-754.
- [bug] `messages list/search/show --limit` no longer crashes or over-fetches on pathological input. A negative limit made SQLite treat `LIMIT -1` as unbounded (whole-DB fetch into memory); a near-`Int.max` limit overflow-trapped `limit + 1` / `limit + excluded.count`. New `MessagesDatabase.clampLimit` normalizes to `[0, 100000]` at all three query entry points. Closes pippin-fvg.
- [bug] Pagination no longer overflow-traps on a huge `--page-size` or crafted cursor. `Cursor.paginate`'s `safeOffset + pageSize` and `pageFromPushdown`'s `offset + pageSize` could trap; `resolve()` now caps `pageSize` at 100000, `paginate` computes the slice end from a remaining-bounded count, and pushdown uses `addingReportingOverflow`. Closes pippin-69k.
- [bug] `SessionManager` (REPL session state) no longer loses concurrent updates. Mutators released the lock, then `save()` re-snapshotted under a separate lock and wrote atomically outside it, so two concurrent mutators' writes were unordered — an older snapshot could land last and revert a sibling field on disk. Persistence now happens inside the mutation's lock. Closes pippin-ym2.
- [bug] `memos export --all --format agent`/`json` no longer hides per-item failures. They were only printed to stdout in non-structured mode, so an all-failed batch returned an empty result set with status `ok` and exit 0. Failures and batch-budget exhaustion now surface as envelope `warnings` (agent) / stderr (json/plain). Closes pippin-290.
- [bug] Date parsing/formatting no longer misbehaves under a non-Gregorian device calendar. `parseDateString` (`memos`/`summarize --since`) lacked `locale = en_US_POSIX` on its fixed `yyyy-MM-dd` formatter, and `TextFormatter.compactDate` used `Calendar.current` — a Buddhist/Japanese-era calendar would misparse the `--since` window or render the wrong year (e.g. 2567 for 2024). Both now pin Gregorian (timezone stays local). Closes pippin-ope.
- [bug] MCP tool calls no longer fail when an argument value starts with `-`. Option values were passed as two argv tokens (`["--flag", value]`), so a value like a search body `-19%` or a markdown-bullet reminder title `- item` was misparsed by ArgumentParser as a stray flag. Option values now bind as `--flag=value`, and free-form positionals (search queries, reminder titles) are appended last behind a `--` separator. Closes pippin-xbm, pippin-bhn.
- [bug] `JSONValue.intValue` (MCP argument extraction) no longer crashes the child on a huge number. A JSON number larger than Int64 decodes as `.double`, and `Int64(value)` traps on an out-of-range/non-finite double — so an arg like `{"limit": 1e19}` crashed the tool call. It now coerces only finite, in-range doubles and returns nil (treated as absent) otherwise. Closes pippin-8y0.
- [bug] `calendar show/edit/delete <prefix>` now works for recurring events. `CalendarBridge.findEventByPrefix` returned nil for every repeating event — its occurrences are separate `EKEvent`s sharing one `calendarItemIdentifier`, so the old `matches.count == 1` check always saw N>1 and bailed. Now dedupes by distinct identifier (extracted to the testable `isUnambiguousPrefixMatch`).
- [bug] `notes list` pagination past the 500-note fetch ceiling no longer silently hides notes 501+. A window beyond the fetch cap sliced a truncated result into an empty page with no cursor and a false "done"; it now throws a clear `ValidationError` when the window exceeds `maxListLimit`.
- [bug] `contacts search --limit` is now honored in the non-paginated path (it previously emitted the full result set; `--limit` only applied as the page size). `contacts search --email` now forces the matched address into output, so `--fields id,fullName` no longer hides the very email that matched.
- [bug] Mail cross-account scans no longer get SIGKILLed under MCP. The list/activity/search hard caps scale up for cross-account scans (to 95s search / 115s activity) — above the 60s MCP `runChild` cap — so a wedged osascript was killed ungracefully instead of self-reaping with partial results. New `MailBridge.clampHardTimeout` clamps every hard cap to 55s under `PIPPIN_MCP` (CLI keeps the full scaled values); the 22s soft cap still fires first in normal operation.
- [bug] Claude API-key resolution no longer hangs. `AIProviderFactory.tryGetSecret` left `stderr` as an undrained `Pipe()`, so a `get-secret` emitting >64KB of stderr blocked on a full pipe buffer and never exited. It now discards stderr at the OS level, drains stdout concurrently, and bounds the wait with a 10s SIGTERM→SIGKILL. Separately, `AudioCommand`'s `isAvailable()` subprocess probe is now hopped off the cooperative pool at all four sites.
- [bug] `RemindersBridge.fetchRemindersSync` no longer hangs forever when EventKit's `fetchReminders` callback never fires (store hang / permission edge) — the bare `semaphore.wait()` is now bounded at 15s, returning partial results with a stderr warning. `DoCommand`'s serial `runChild` loop is hopped off the cooperative pool via `detachBlocking`.
- [bug] `reminders list --due-before`/`--due-after` no longer include reminders that have no due date. They were treated as passing (so an undated reminder showed up in both `--due-before X` and `--due-after X`); an undated reminder now fails any due filter, matching the `--created-after`/`--modified-after` behavior. Closes pippin-cbr.
- [bug] `pippin digest --calendar-days N` now covers the full N days beyond today. The upcoming window was anchored to start-of-today, so it spanned only N−1 days (the default 7 dropped the 7th day's events). `--calendar-days` is also now bounded to 1–366 so a huge value can't overflow the date arithmetic. Closes pippin-921.
- [bug] The always-on prompt-injection rule scanner (`PromptInjectionScanner`) no longer misses phrases that are obfuscated with extra whitespace. Patterns like "ignore previous instructions" used literal substring matching, so `"ignore  previous\ninstructions"` (padded or line-broken) slipped past the rule pass. The systemPromptOverride / dataExfiltration / roleHijacking phrases now match with whitespace-tolerant regex (`word\s+word`), and `sanitize()` still redacts the real matched text. Closes pippin-z3c.

### Changed

- [refactor] Unified `MailBridge.SearchMeta` / `ListMeta` / `ActivityMeta` (three byte-identical Decodable structs with the same custom init), `SearchResponse` / `ListResponse` / `ActivityResponse`, and `SearchOutcome` / `ListOutcome` / `ActivityOutcome` into `ScanMeta` / `ScanResponse` / `ScanOutcome`. Legacy names kept as typealiases so existing callers compile unchanged. ~80 lines of duplication removed. Closes pippin-660.
- [build] `Makefile` — `make build` and `make test` now invoke `xcrun --sdk macosx swift {build,test}` so they route through `xcode-select`. CLT-only macOS 26 hosts get a clear hint to install Xcode or set `DEVELOPER_DIR`. Closes pippin-ncr.
- [refactor] Lifted the duplicated per-bridge `Outcome<T>` (NotesBridge + ContactsBridge) into a shared `pippin/Formatting/BridgeOutcome.swift`, resolving the Decodable/pure-Swift mismatch via conditional conformance (`extension BridgeOutcome: Decodable where T: Decodable`). `MailBridge.ScanOutcome` stays separate by design. Closes pippin-a9v.
- [ci] `scripts/lint-detach-blocking.py` — async-aware brace-stack analyzer that flags `async` commands calling blocking bridge work without `detachBlocking` (strips comments/strings, handles same-line wraps, `// detach-lint:allow` suppression, `--self-test`); wired into the CI gates. It found and fixed 16 cooperative-pool gaps across Mail/Notes/Contacts. Closes pippin-avc, pippin-8aa.
- [build] Local CI moved off GitHub-hosted runners. `make ci` runs the full gates natively (build + test + swiftformat + detach-lint); `make ci-vm` runs them in an ephemeral, isolated macOS VM via Tart (`scripts/ci-vm.sh` clones a fresh image, rsyncs the tree, runs the gates, destroys the VM). The GitHub `ci.yml` workflow is disabled — `make ci`/`ci-vm` is now the pre-push gate.

### Documentation

- [docs] `docs/ROADMAP.md` rewritten — every one of the previous file's 13 listed roadmap items had landed and closed. Restructured into Deferred (3 explicitly-deferred beads) and Shipped (v0.16 → v0.22) sections.
- [docs] `docs/mcp-server.md` — tool count refreshed (33 → 44, added the messages_*, mail_activity, memos_capture_to_reminders, digest tools). [agent]/known-consumers section updated to reflect [agent-runtime]-Agent-on-M5 ([agent] drives pippin natively over stdio MCP rather than shelling out from a Pi).
- [docs] `README.md` — install URL no longer pin-points v0.14.2 specifically; replaced with a generic vX.Y.Z placeholder pointing at the Releases page.
- [docs] `docs/agent-prompts/{review-and-ship,autonomous-audit}.md` — retired the Forgejo PR-creation flow (Forgejo retired 2026-04-17 in favor of GitHub canonical); replaced with `gh pr create`. Test-count baseline 831 → ~1648. Audit checklist gained a Concurrency section and codified envelope v1 + outcome.timedOut surfacing as AX contracts.
- [docs] `docs/gotchas/swift.md` — new "Cooperative-thread blocking — use `detachBlocking`" section covering where the blocking lives, the mechanical fix, and the two recurring traps (mutable struct self-capture, captured-var test counters).
- [docs] Toolchain/CI/dependency drift cleanup: README Swift toolchain floor aligned to 6.0 (matches `Package.swift`); `copilot-setup-steps.yml` `setup-xcode` pin normalized to match ci/codeql/release (with a note on why Forgejo CI omitted it); the `.upToNextMinor` + `Package.resolved` revision-pin dependency policy documented in `Package.swift`. Closes pippin-7gb, pippin-n7q, pippin-9vh.
- [docs] `docs/local-ci.md` + CLAUDE.md document the Tart `make ci-vm` / native `make ci` flow and that the GitHub `ci.yml` is disabled.

---

## [0.23.0] - 2026-05-19

### Added

- [feat] MailBridge cross-account timeout scaling (`listMessages`, `listActivity`, `searchMessages`). When no `--account` filter is set (cross-account scan across all configured accounts), the ScriptRunner hard cap is auto-increased so commands no longer hard-timeout before JXA finishes: `list` 10s→60s, `list --preview` 50s→100s, `activity` 50s→75s (115s with preview), `search` 30s→50s, `search --body` 45s→95s. Single-account calls are unaffected. Closes pippin-j3g.

### Fixed

- [bug] `pippin mail list` (no `--account`) no longer hard-times out on multi-account setups — cross-account INBOX scan across 5+ accounts now gets 60s (was 10s). Partial results via the 22s soft timeout surface quickly; full scan finishes within the hard cap. Closes pippin-j3g.
- [bug] `pippin mail search <query> --body` (no `--account`/`--mailbox`) no longer hard-times out — cross-account body search now gets 95s (was 30s). Searches across 5 accounts × ~30 mailboxes with per-message IMAP body fetches complete successfully.
- [bug] `pippin mail activity` (no `--account`) no longer hard-times out — cross-account activity scan now gets 75s (was 50s), 115s with preview (was 90s). Scans 5 accounts × INBOX + Sent within the cap.

### Changed

- [refactor] `MailBridge.listMessages`, `listActivity`, `searchMessages` now auto-detect cross-account via `crossAccount = (account == nil)` (and `&& (mailbox == nil)` for search) and apply the appropriate timeout multiplier. No API surface change — all existing callers work unchanged.

---

## [0.22.0] - 2026-04-24

### Added

- [feat] `pippin messages` subcommand — read and send access to Apple Messages (`~/Library/Messages/chat.db` via GRDB). Read subcommands: `list` (recent conversations, most-recent first), `search <query>` (substring match over message bodies), `show <conversation-id>` (thread view by GUID), `exclude {list,add,remove} <thread>` (per-thread opt-out stored in config). Handles both the post-macOS-10.13 nanosecond date column and the legacy seconds format. Agent/JSON output obeys envelope v1. Audit log at `~/.local/share/pippin/messages-audit.jsonl` records every read/send op (no message bodies persisted). MCP tools: `messages_list`, `messages_search`, `messages_show`, `messages_send` (draft-only via MCP). Requires Full Disk Access for the invoking terminal.
- [feat] `pippin messages send --to <handle> --body <text>` — defaults to `--draft` (log-only, no delivery). Autonomous delivery (`--autonomous`) is triple-gated: env var `PIPPIN_AUTONOMOUS_MESSAGES=1` AND recipient in `config.messages.autonomousAllowlist` AND explicit `--autonomous` flag. PHI filter (SSN, credit card, API key, PEM, password mention) blocks send and records category names in the audit log.

---

## [0.21.0] - 2026-04-25

### Added

- [feat] `pippin memos capture --to-reminders` — transcribe the most recent voice memo (or `--memo <id>`), extract action items via the configured LLM, and create Reminders in one shot. Chains existing `VoiceMemosDB`/`TranscriptCache`/`MLXAudioTranscriber` → `AIProvider` → `RemindersBridge`; no new infrastructure. Supports `--list <name>` (default: Inbox), `--dry-run` (auto-on for TTY text output; commits by default for `--format json` / `--format agent`). MCP tool: `memos_capture_to_reminders`. New built-in template `capture-action-items` enforces JSON shape `{items: [{title, due_hint, notes}]}`.

---

## [0.20.3] - 2026-04-24

### Deprecated

- [deprecation] `pippin audio` and `pippin browser` subcommands are now hidden by default. Set `PIPPIN_EXPERIMENTAL=1` to re-enable them — existing scripts with the env var continue to work unchanged. These commands will be **removed in the next major release (v1.0.0)** unless an issue is filed against `github.com/mattwag05/pippin` requesting otherwise. Rationale: they're rarely used and carry outsized maintenance cost (mlx-audio Python subprocess, Playwright WebKit bundle). Code and tests remain in place so re-enabling requires no rebuild.

---

## [0.20.2] - 2026-04-23

### Fixed

- [fix] `contacts list` (no `--group`) and `contacts search --email` now return partial results with a `warnings` entry rather than hanging MCP clients when the Contacts store is large. Wall-clock soft timeout defaults to 22s, clamped `[1s, 5min]`, matching the mail/notes pattern. Group-filtered list and name search are unaffected (they use bounded Contacts predicates).

### Changed

- [refactor] Extracted the `clampSoftTimeoutMs` helper and 22s default into a shared `SoftTimeout` enum. NotesBridge and ContactsBridge callers now share a single definition; the JXA-side inline clamps stay put (different language) but agree on the same bounds.

---

## [0.20.1] - 2026-04-23

### Fixed

- [fix] `mail_search` and `notes_{list,search,folders}` now return partial results with a `warnings` entry rather than hanging MCP clients when Mail.app / Notes.app is slow (default soft timeout: 22s, clamp `[1s, 5min]`, configurable via `--soft-timeout-ms`). Legacy `{results}` payloads continue to decode.
- [refactor] Consolidated timeout-warning emission across Mail + MCP runtime into a shared `OutputOptions.emit(..., timedOut:, timedOutHint:)` helper; hardens a small race where the warning could be emitted twice.

---

## [0.20.0] - 2026-04-21

### Breaking

- [agent] Envelope v1 — every `--format agent` response is now wrapped in `{"v":1,"status":"ok","duration_ms":N,"data":<payload>}` (or `{"v":1,"status":"error",…,"error":{…}}`). The previous raw payload lives unchanged under `.data`, so single-field extractions like `.error.code` keep working; iterations like `jq 'length'` must be rewritten as `jq '.data | length'`. Canonical constant: `AGENT_SCHEMA_VERSION` in `pippin/Formatting/AgentOutput.swift`. Morning-briefing scheduled task already migrated. Consumer migration notes in `docs/mcp-server.md`.

### Added

- [feat] `pippin do "<intent>"` — LLM-planned sub-command execution. Reads the MCP tool registry as the tool schema, prompts the active AIProvider for a JSON plan (with one self-repair retry), validates step args against each tool's `inputSchema`, then executes via `pippin batch`. `--dry-run` stops before execution; `--max-steps N` caps plan size.
- [feat] `pippin job run/show/list/wait/logs/gc` — detached-child jobs subsystem. State under `~/.cache/pippin/jobs/<ulid>/{status.json,stdout.log,stderr.log}`. Matching MCP tools `job_run`, `job_show`, `job_list`, `job_wait` so agents can fire long-running work without blocking the tools/call channel.
- [feat] `pippin batch` — reads a JSON array of `{cmd,args}` on stdin, runs each entry concurrently (subprocess per entry, `--concurrency` default 4), returns an enveloped array of per-item envelopes. MCP companion tool `batch` registered — a single `tools/call` can parallelize N things.
- [feat] `pippin mail watch` — polls configured accounts and emits newline-delimited JSON events for new messages. Options: `--account`, `--mailbox`, `--interval`.
- [feat] `pippin contacts create/edit/delete` — write support on top of the existing read-only bridge. Uses `CNMutableContact` + `CNSaveRequest`. `--force` required for destructive ops.
- [feat] `pippin mail triage` rules engine — persistent per-user rules at `~/.config/pippin/triage-rules.json` apply before (or instead of) the AI pass, covering auto-label, auto-archive, and priority overrides by sender/subject/keywords. Cuts tokens spent on predictable traffic.
- [feat] Browser retry flags — `pippin browser open/fetch/snapshot` gained `--retry N`, `--expect-field <json.path>`, `--retry-delay-ms <ms>`. Response envelope adds `data._attempts` whenever `--retry > 0` is passed.
- [feat] Pagination cursors — `--cursor <token>` + `--page-size N` on `mail list`, `mail search`, `memos list`, `reminders list`, `notes list`, `calendar events`, `calendar upcoming`, `contacts search`. When either flag is set, `envelope.data` becomes `{items, next_cursor}`; bare-array shape preserved otherwise. Cursor is `base64url(json({offset, filter_hash}))` with SHA-256 filter hash to reject cross-query reuse.
- [feat] REPL tab completion — command names, subcommands, flag names, and contextual values (mail account names, reminder list names).

### Changed

- [ops] Jobs / MCP tool table refreshed in `docs/mcp-server.md`.

### Fixed

- [fix] REPL flag suggestions now honor command-specific flag sets; `mail triage` shows triage-specific flags in suggestions.
- [fix] `pippin mail watch`: hoist `WatchEvent`, fix an overflow on long-poll runs, surface encoder errors instead of swallowing them.
- [chore] Remove stray backup file from the tree; sync beads interactions log.

---

## [0.19.0] - 2026-04-20

### Added

- [feat] `pippin actions extract` — scans recent Sent mail and recently-modified Notes for first-person commitments ("I'll send Q3 numbers by Friday") and emits a structured list of draft reminders. Batches items 10 per AI call, 4 concurrent (mirrors `TriageEngine`). `--create` flag chains into `RemindersBridge` to write reminders directly. Supports `--days`, `--no-mail`, `--no-notes`, `--account`, `--limit`, `--min-confidence`, `--provider`, `--model`, `--list`, and `--format text|json|agent`.

---

## [0.18.0] - 2026-04-18

### Added

- [feat] `ErrorCategory` enum — closed set of snake_case error codes backs `RemediationCatalog`, so a typo fails to compile instead of silently returning `nil`. Agent JSON shape is unchanged.
- [feat] mlx-audio STT three-tier entry resolution — prefers the pipx-installed `mlx_audio.stt.generate` binary, falls back to `-m mlx_audio.stt.generate` (0.4.2+), then `-m mlx_audio.stt` (legacy). Pinned version `0.4.2` lives in `AudioBridge.pinnedMLXAudioVersion`. `AudioBridgeError.versionMismatch` surfaces skew with install-vs-pinned remediation.
- [feat] `pippin doctor` mlx-audio check now reports installed version via `importlib.metadata`, runs a dry `--help` invocation, and calls out version mismatches with an exact `pipx install 'mlx-audio==<pinned>' --force` remediation.
- [feat] 5 new MCP tools — `memos_list`, `memos_info`, `memos_export`, `memos_transcribe`, `memos_summarize`. Brings the registry to 31 tools. `docs/mcp-server.md` updated.
- [feat] `AudioConverter` — AVFoundation-based transcoder that normalizes non-native audio formats to 16 kHz mono PCM WAV before STT. `memos transcribe --keep-converted` preserves the temp WAV and prints its path for debugging. `.wav` and `.m4a` (Voice Memos native) skip conversion.
- [feat] Homebrew formula `post_install` runs `pipx install mlx-audio==<pinned>` when `pipx` is on PATH (falls back with a hint otherwise). Homebrew-pipx venv path added to `AudioBridge`'s candidate list.

### Changed

- [refactor] `DiagnosticCheck.remediation` is now `Remediation?` (was `String?`). `pippin doctor --format json` emits structured `{human_hint, doctor_check, shell_command}` instead of a free-form string. Text rendering still groups the hint prose with a `$ <cmd>` suffix line, so non-JSON output reads the same or better.
- [refactor] All FDA remediation text unified into one catalog entry in `Remediation.swift` — previously duplicated across three Doctor branches + the catalog. Grep `Full Disk Access` across `pippin/` now returns the single canonical home plus docstring references.

---

## [0.17.0] - 2026-04-12

### Added

- [feat] `pippin mcp-server` — expose pippin as a Model Context Protocol server over stdio so Claude Code, Claude Desktop, Cursor, and other MCP-compatible clients can attach directly instead of shelling out to the CLI. Ships with 26 tools covering mail, calendar, reminders, contacts, notes, status, and doctor. Each `tools/call` spawns `pippin <cmd> --format agent` as a child process so the MCP path has perfect parity with the existing CLI path. See `docs/mcp-server.md` for wiring details.

---

## [0.16.0] - 2026-04-10

### Added

- [feat] `pippin status` — system dashboard showing mail accounts, calendar events, reminders, voice memos, notes, contacts, and TCC permission status; supports `--format text|json|agent`
- [feat] Session state persistence — REPL sessions persist active account, last-used IDs, and command history to `~/.config/pippin/session.json`; built-in commands: `use <account>`, `context`, `history`
- [feat] `pippin init --format json|agent` — structured output for the init/doctor guided setup
- [feat] `SKILL.md` — agent discovery manifest with YAML frontmatter and full command reference
- [feat] `runConcurrently<Input, Output>()` — generic concurrent dispatch helper with optional rate limiting and fail-fast support (`ConcurrencyUtils.swift`)
- [ci] GitHub Copilot coding agent — `.github/copilot-setup-steps.yml` environment + `.github/workflows/copilot-ci-fix.yml` auto-creates issues on CI failure for Copilot to fix

### Changed

- [refactor] `TriageEngine` — replaced private `runBatchesConcurrently` (~30 lines) with `runConcurrently(batches, maxConcurrent: 4, failFast: true)`
- [refactor] `SemanticSearch` — replaced inline DispatchGroup+NSLock pattern with `runConcurrently`
- [docs] `CLAUDE.md` — added session state, status command, Copilot CI-fix workflow, and lint tips
- [docs] `AGENTS.md` — added Copilot coding agent section with failure patterns and quality gates

### Added (Tests)

- `StatusCommandTests` — 7 tests covering status report building and output formats
- `ConcurrencyUtilsTests` — 7 tests covering concurrent dispatch, rate limiting, fail-fast, empty input
- `InitCommandTests` — 8 tests covering init report structure and format options
- `SessionStateTests` — 11 tests covering persistence, thread safety, atomic writes, history capping
- 914 → 1049 tests, 0 failures

---

## [0.15.0] - 2026-04-10

### Added

- [feat] ShellCommand: interactive REPL mode — `pippin shell` or bare `pippin` with no subcommand drops into a session where commands are entered without the `pippin` prefix
- [feat] Session-wide `--format` flag: `pippin shell --format json` injects format into all commands
- [feat] Non-interactive pipe mode: `echo "calendar agenda" | pippin shell --format agent` for scripting
- [feat] Quote-aware argument splitting (`shellSplit`) for command lines with quoted strings
- [test] ShellCommandTests: 13 new tests covering argument splitting and command parsing

### Changed

- [ux] Bare `pippin` now defaults to REPL instead of printing help
- [docs] README: added Interactive Shell section, REPL sample workflows, architecture table entry
- [docs] CLAUDE.md: documented REPL shell architecture and parser injection pattern

---

## [0.14.3] - 2026-04-10

### Fixed

- [fix] vault-scan: tighten Basic Auth URL regex to prevent false positives on Google Fonts URLs with @ in query parameters
- [fix] vault-serve: use correct Vaultwarden item name `Anthropic API` for secret lookup (was `Antropic API`)

### Changed

- [perf] EmbeddingStore: use Accelerate/vDSP for vectorized cosine similarity (replaces manual loop)
- [perf] EmbeddingProvider: add `embedBatch` protocol method with native Ollama batch implementation (single HTTP request per batch)
- [perf] MailAICommand: refactor indexing from individual concurrent embeds to batched embedding (32 per batch, fewer HTTP round-trips)
- [perf] SemanticSearch: load matched messages concurrently via DispatchGroup instead of sequential JXA calls
- [perf] TriageEngine: check firstError before each rate-limiter wait to abort dispatch loop early on failure

### Added

- [docs] README.md: rebrand with logo, badges, and streamlined copy
- [tooling] beads issue tracking initialized

---

## [0.14.2] - 2026-04-03

### Added

- [docs] CLAUDE.md: AI Provider Configuration section with model comparison table (Gemma 4 vs Qwen 3.5 vs Claude Sonnet 4.6), config resolution order, Claude API key resolution chain, and [agent] as a known consumer
- [docs] README.md: AI Configuration section with provider setup, config.json format, and per-command override syntax
- [docs] README.md: updated memos summarize examples to show Ollama model selection

---

## [0.14.1] - 2026-03-23

### Changed

- [quality] MemosCommand.swift: replace 8 verbose `!outputOptions.isJSON, !outputOptions.isAgent` progress guards with the canonical `!outputOptions.isStructured` — consistent with `SummarizeCommand` and the documented pattern
- [quality] CalendarCommand.swift: refactor `SmartBriefing` output block from combined `if isJSON || isAgent {}` to the standard three-way `if isJSON / else if isAgent / else` pattern

---

## [0.14.0] - 2026-03-21

### Fixed

- [ax] MemosCommand.swift: `memos export` had a hidden `--format` collision — the sidecar transcript format option (`txt`, `srt`, `markdown`, `rtf`) shadowed the `OutputOptions --format` flag, causing ArgumentParser to fatal-error whenever `--format` was used; renamed to `--sidecar-format` (matching the `AudioCommand.Transcribe` fix in v0.13.0)

### Changed

- [ax] BrowserCommand.swift: `browser screenshot`, `click`, `fill`, `scroll`, `close` now support `--format text|json|agent`; action commands return `BrowserActionResult{success,action,details}` in structured modes
- [ax] MemosCommand.swift: `memos delete` now supports `--format text|json|agent`; returns `MemosActionResult{success,action,details}` in structured modes
- [quality] AgentOutput.swift: fix opening brace spacing (SwiftLint `opening_brace` warning)
- [quality] TemplateManager.swift: replace for-loop with `first(where:)` to satisfy SwiftLint `for_where` rule

### Added

- [test] BrowserCommandTests.swift: 13 new tests covering `--format agent/json/text` parsing for Screenshot, Click, Fill, Scroll, Close + `BrowserActionResult` encoding
- [test] MemosCommandTests.swift: 55 new tests covering all 5 MemosCommand subcommands (List, Info, Export, Transcribe, Delete) — argument parsing, validation, and format options
- [test] CalendarCommandTests.swift: 15 new tests for `calendar today`, `calendar remaining`, `calendar upcoming` subcommands — argument parsing and format options
- 844 → 914 tests, 0 failures

---

## [0.13.0] - 2026-03-15

### Added

- Structured agent error output: when `--format agent` is active, unhandled errors emit `{"error":{"code":"snake_case_code","message":"..."}}`  to stdout (via `AgentError` + `printAgentError()` in `AgentOutput.swift`)
- `BrowserCommandTests` — parse/validate tests for all 9 browser subcommands + `BrowserBridgeError` descriptions
- `AudioCommandTests` — parse/validate tests for all 4 audio subcommands + `AudioBridgeError` descriptions
- `ContactsCommandTests` — parse/validate tests for all 4 contacts subcommands

### Changed

- `MailBridge.swift` split into four focused files: `MailBridgeScripts.swift`, `MailBridgeHelpers.swift`, `MailBridgeRunner.swift` (core API methods remain in `MailBridge.swift`); removes `swiftlint:disable file_length`
- `MailBridgeError` moved to `MailModels.swift` (public, `Sendable`)
- `AudioBridgeError` moved from `AudioBridge.swift` to `AudioModels.swift` (public, `Sendable`)
- `BrowserBridgeError.actionFailed(String)` replaced with typed cases: `scriptFailed(String)`, `decodingFailed(String)`, `timeout` — matching Mail/Notes pattern
- `AudioCommand.Transcribe` renames `--format` to `--transcription-format` (was colliding with `OutputOptions --format`)
- 703 → 819 tests, 0 failures

---

## [0.12.0] - 2026-03-13

### Added

- `pippin doctor --format agent` — compact JSON output for AI agent consumption
- `pippin doctor` now checks Python 3 availability as a separate named check
- `pippin doctor` Notes.app pre-check via `pgrep` — faster fail when Notes is not running
- `classifyMailError()` and `classifyPython3Output()` extracted as testable public helpers
- `DoctorTests` — unit tests for mail error classification, python3 detection, and permission-denied remediation format

### Fixed

- Doctor command remediation strings unified: agent-runnable commands use `$` prefix, human-only instructions have no `$` prefix
- Notes.app timeout remediation simplified to `$ open -a Notes && sleep 2`
- Node.js remediation updated to `$ brew install node`
- Playwright remediation updated to `$ npx playwright install webkit`
- Transcription unified on `mlx-audio` (AudioBridge) — removes separate `parakeet-mlx` binary dependency
- `pippin memos transcribe` and `pippin memos export --transcribe` now read/write transcript cache (no more redundant transcription)
- `pippin doctor` no longer checks `parakeet-mlx` or Speech Recognition; `mlx-audio` check promoted from optional to required
- `MLXAudioTranscriber` replaces `ParakeetTranscriber`/`SpeechFrameworkTranscriber`/`TranscriberFactory` (dead code removed)

### Changed

- `pippin memos transcribe`, `pippin memos export`, and `pippin memos summarize` support `--jobs N` for parallel batch processing (default: 2)
- `pippin memos transcribe` gains `--force` flag to bypass transcript cache
- `pippin memos export` gains `--force-transcribe` flag to bypass transcript cache

---

## [0.11.0] - 2026-03-10

### Added

- `--format agent` output mode across all commands: compact (non-pretty-printed) JSON for AI agent consumption
- `OutputFormat.agent` case added to `OutputFormat` enum (alongside `text` and `json`)
- `OutputOptions.isAgent` computed property for command dispatch
- `printAgentJSON<T: Encodable>()` helper in `AgentOutput.swift` — uses `JSONEncoder` with no formatting options (compact by default)
- Agent mode for action results (create/edit/delete/complete/send/move/mark) — same as `json` (already compact)
- Agent mode for `notes show` uses `NoteAgentView` — excludes large HTML body, includes `plainText`, reducing token usage
- Claude Code plugin at `~/.claude/plugins/pippin/` — skill that teaches Claude to use pippin for Apple app automation

---

## [0.10.0] - 2026-03-10

### Added

- `pippin notes` subcommand: `list`, `show`, `search`, `folders`, `create`, `edit`, `delete`
- JXA (JavaScript for Automation) subprocess bridge for Notes.app automation
- Notes sorted by modification date (newest first)
- `--folder` filter for `list` and `search` subcommands
- `--append` flag on `edit` to append body content instead of replacing
- `--force` required for `delete` to prevent accidental note removal
- `--fields` JSON field filtering for `list` and `search` (JSON output only)
- `pippin doctor` now reports Notes.app automation TCC permission status

---

## [0.9.0] - 2026-03-10

### Added

- `pippin reminders` subcommand: `lists`, `list`, `show`, `create`, `edit`, `complete`, `delete`, `search`
- EventKit-based Reminders bridge using EKEventStore with `.reminder` entity type
- Priority filtering and display (high/medium/low/none mapping to EKReminder priority values 1/5/9/0)
- Due date filtering via `--due-before` and `--due-after` flags
- `pippin doctor` now reports Reminders TCC permission status

---

## [0.8.0] - 2026-03-10

### Added

- `pippin browser` subcommand: `open`, `snapshot`, `screenshot`, `click`, `fill`, `scroll`, `tabs`, `close`, `fetch`
- Playwright WebKit subprocess bridge with persistent session support
- Accessibility tree parsing with @ref IDs for AI agent interaction
- `pippin doctor` now reports Node.js and Playwright availability (optional dependencies)

---

## [0.7.0] - 2026-03-10

### Added

- `pippin calendar events --fields`: comma-separated JSON field filtering
- `pippin calendar events --range`: date shorthands (`today`, `today+N`, `week`, `month`)
- `pippin calendar events --type`: filter by calendar type (calDAV, exchange, local, etc.)
- `pippin calendar list --type`: filter calendars by type
- New subcommands: `today`, `remaining`, `upcoming` (convenience aliases)

---

## [0.6.0] - 2026-03-10

### Added

- `pippin contacts` subcommand: `list`, `search`, `show`, `groups`
- CNContactStore-based contacts access (read-only)
- `--fields` flag for token-efficient field filtering on list/search
- `pippin doctor` now reports Contacts TCC permission status

---

## [0.5.0] - 2026-03-10

### Added

- `pippin audio` subcommand: `speak`, `transcribe`, `voices`, `models`
- Python mlx-audio subprocess bridge (TTS via Kokoro, STT via Parakeet/Whisper)
- `pippin doctor` now reports mlx-audio availability (optional dependency)

---

## [0.4.0] - 2026-03-09

### Fixed

- `mail search` now scans **newest messages first** (was oldest-first, causing recent emails to be missed in large mailboxes)
- Per-mailbox scan limit raised from 50 to 200 messages
- Error messages include actionable suggestions (e.g., timeout now says "try --account or --after")
- `to:` field is now populated in `mail search` results (was always empty `[]`)

### Added

- `--after YYYY-MM-DD` — only include messages on or after this date
- `--before YYYY-MM-DD` — only include messages on or before this date
- `--to <email>` — filter search results by recipient address
- `--verbose` — print search diagnostics to stderr (accounts/mailboxes scanned, messages examined, body search status)

---

## [0.3.1] - 2026-03-09

### Added

- `pippin mail reply <id> --body "..."` — reply to a message; optional `--to` to override recipient
- `pippin mail forward <id> --to <addr>` — forward a message; optional `--body` for additional text
- `pippin mail attachments <id>` — list attachments; `--save-dir <path>` to save to disk
- `--bcc` flag on `mail send`, `mail reply`, `mail forward`
- `--to`, `--cc`, `--bcc`, `--attach` are now repeatable (accept multiple values)

### Changed

- Email address and attachment path validation extracted to shared helpers (DRY)
- Reply/forward quoting built in Swift (`buildReplyQuote`, `buildForwardPrefix`) before JXA execution
- `buildSaveAttachmentsScript` uses `resolveMailbox` helper for alias support

---

## [0.3.0] - 2026-03-06

### Added

- `pippin calendar` — new command group for Apple Calendar automation using EventKit
- `pippin calendar list` — list all calendars (NAME, TYPE, ACCOUNT, COLOR columns)
- `pippin calendar events` — list events; `--from`, `--to`, `--calendar`, `--limit 50`; defaults to today
- `pippin calendar show <id>` — full event card with attendees, recurrence, notes, URL
- `pippin calendar create --title --start` — create event; `--end` (default: +1h), `--location`, `--notes`, `--all-day`, `--url`, `--calendar`
- `pippin calendar edit <id>` — update any field on an existing event
- `pippin calendar delete <id> --force` — delete an event (requires `--force`)
- `pippin calendar smart-create "<description>"` — AI parses natural language → creates event; `--dry-run` to preview parsed JSON
- `pippin calendar agenda` — AI-generated daily/weekly briefing; `--days 1` (max 7)
- `pippin doctor` now checks Calendar TCC permission and reports ok/skip/fail
- 2 built-in AI templates: `smart-create-calendar`, `calendar-briefing`
- Event IDs use `calendarItemIdentifier` (stable UUID); prefix matching (8+ chars) supported
- All `pippin calendar` subcommands accept `--format json`

---

## [0.2.1] - 2026-03-06

### Fixed

- `mail move --to Trash` (and `Deleted`, `Junk`, `Spam`, `Sent`, `Drafts`, `Bin`) now resolves the correct provider mailbox via JXA special accessors (`acct.trash()`, `acct.junk()`, `acct.sent()`, `acct.drafts()`), fixing failures on Gmail, iCloud, and Exchange accounts where the folder name varies by provider (fixes #4)
- `mail list --mailbox <alias>` and `mail search --mailbox <alias>` use the same alias resolver, so `--mailbox Trash` works regardless of provider naming
- `mail show` now fetches plain-text content first to trigger the IMAP body download before attempting `htmlContent()`, and retries once after 500 ms if `htmlBody` is still null — fixes `htmlBody: null` on undownloaded IMAP messages (fixes #3)

---

## [0.2.0] - 2026-03-05

### Added

- `memos summarize <id>` — AI-powered summarization of voice memo transcripts; saves Markdown summary to output directory
- `memos templates` — list and manage summarization prompt templates (5 built-in + user-defined)
- `memos delete <id> --force` — permanently delete a voice memo from the Voice Memos database
- AI provider layer: Ollama (local) and Claude (Anthropic API) backends; configurable via `pippin init` or `--provider`
- Transcript cache: transcripts saved alongside audio exports, reused on subsequent summarize calls
- `--format` flag for `memos export` output (text/json, consistent with other subcommands)
- 34 new tests (228 total, 0 failures)

### Fixed

- `createdAt` timestamp now used correctly for summary filename (was using file modification date)
- `builtIn` field in template JSON now encodes as boolean (was encoding as integer)

### Changed

- Reduced duplication in `MailBridge`, `DoctorCommand`, and memos commands

---

## [0.1.0] - 2026-03-05

### Added

- `pippin completions <shell>` — generate shell completion scripts (`zsh`, `bash`, `fish`); `make completions` installs to `~/.zfunc/_pippin`
- `pippin mail mailboxes` — list all mailboxes for an account; `--account` filter
- `pippin mail list` — `--page` flag for paginated browsing, `--has-attachment` filter
- `pippin mail show` — enriched output with `htmlBody`, `headers`, and `attachments[]` (name, mimeType, size)
- `pippin memos info` — prefix ID matching (first 8 chars of UUID)
- GitHub Actions CI (`.github/workflows/ci.yaml`) — build, test, lint on GitHub push and PR
- Forgejo Actions CI enforces `swiftformat --lint` across all three source dirs

### Changed

- `pippin mail search` — timeout increased from 10 s to 30 s; fixes timeouts on large IMAP mailboxes
- All source migrated to Swift 6 strict concurrency (`swiftLanguageMode(.v6)`); all `Sendable` conformances and `nonisolated(unsafe)` patterns applied
- macOS platform minimum set to macOS 15+

### Fixed

- `pippin memos` prefix ID matching now resolves correctly against GRDB UUID column

---

## [0.1.0-beta] - 2026-03-02

Initial beta release. Single arm64 binary, human-readable text output, guided setup.

### Added

**Core**
- `pippin --version` — print version string
- `pippin doctor` — check macOS version, Mail TCC, Voice Memos DB access, parakeet-mlx, Speech Recognition; exits 1 on critical failure; `--format json` for scripting
- `pippin init` — guided first-run setup with step-by-step remediation for each failed check
- `--format text|json` on every subcommand (default: text)

**Mail**
- `pippin mail accounts` — list configured Mail accounts
- `pippin mail list` — list inbox messages (limit 20, `--unread`, `--mailbox`, `--account`)
- `pippin mail search <query>` — search by subject, sender, or body (limit 10)
- `pippin mail show <id>` — show full message; `--subject` shortcut to search-then-show
- `pippin mail mark <id> --read|--unread` — mark message read status (`--dry-run`)
- `pippin mail move <id> --to <mailbox>` — move message to another mailbox (`--dry-run`)
- `pippin mail send --to --subject --body` — send email; optional `--cc`, `--from`, `--attach`, `--dry-run`
- `pippin mail read` — hidden alias for `show` (backward compat)

**Memos**
- `pippin memos list` — list recordings as text table; `--since YYYY-MM-DD`, `--limit`
- `pippin memos info <id>` — full metadata card for a recording
- `pippin memos export <id|--all> --output <dir>` — copy audio file(s) to directory; `--transcribe` for transcript sidecar

**Infrastructure**
- GRDB.swift 7.0 dependency — read-only SQLite access to Voice Memos database (replaces Python subprocess)
- `TextFormatter` — 80-column table/card/truncate/duration/date formatting for all text output
- Apache 2.0 LICENSE
- `Makefile` with `build`, `test`, `lint`, `install`, `version`, `release`, `clean` targets
- Forgejo Actions CI (`.forgejo/workflows/ci.yaml`) — build, test, lint on every push and PR

### Changed

- `pippin mail read` renamed to `pippin mail show` (`read` kept as hidden alias)
- `pippin mail list` default limit: 50 → 20
- `pippin memos` rewritten in Swift with GRDB (was Python subprocess via `pippin-memos`)
- Default output format changed from JSON to human-readable text (`--format json` for scripting)

### Removed

- Python `pippin-memos` package (archived to `archive/pippin-memos/`)
- `pippin memos delete` — dropped from v0.1 scope (sandboxing concerns)
- Xcode project (`pippin.xcodeproj`) — SPM is the build system
- `make install-memos` and `make install-all` targets (no Python)

---

[Unreleased]: https://github.com/mattwag05/pippin/compare/v0.31.0...HEAD
[0.31.0]: https://github.com/mattwag05/pippin/compare/v0.30.0...v0.31.0
[0.30.0]: https://github.com/mattwag05/pippin/compare/v0.29.0...v0.30.0
[0.29.0]: https://github.com/mattwag05/pippin/compare/v0.28.0...v0.29.0
[0.28.0]: https://github.com/mattwag05/pippin/compare/v0.27.0...v0.28.0
[0.27.0]: https://github.com/mattwag05/pippin/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/mattwag05/pippin/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/mattwag05/pippin/compare/v0.24.3...v0.25.0
[0.24.3]: https://github.com/mattwag05/pippin/compare/v0.24.2...v0.24.3
[0.24.2]: https://github.com/mattwag05/pippin/compare/v0.24.1...v0.24.2
[0.24.1]: https://github.com/mattwag05/pippin/compare/v0.24.0...v0.24.1
[0.24.0]: https://github.com/mattwag05/pippin/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/mattwag05/pippin/compare/v0.22.0...v0.23.0
[0.20.2]: https://github.com/mattwag05/pippin/compare/v0.20.1...v0.20.2
[0.20.1]: https://github.com/mattwag05/pippin/compare/v0.20.0...v0.20.1
[0.20.0]: https://github.com/mattwag05/pippin/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/mattwag05/pippin/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/mattwag05/pippin/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/mattwag05/pippin/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/mattwag05/pippin/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/mattwag05/pippin/compare/v0.14.3...v0.15.0
[0.14.3]: https://github.com/mattwag05/pippin/compare/v0.14.2...v0.14.3
[0.14.2]: https://github.com/mattwag05/pippin/compare/v0.14.1...v0.14.2
[0.14.1]: https://github.com/mattwag05/pippin/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/mattwag05/pippin/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/mattwag05/pippin/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/mattwag05/pippin/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/mattwag05/pippin/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/mattwag05/pippin/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/mattwag05/pippin/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/mattwag05/pippin/compare/v0.4.0...v0.8.0
[0.4.0]: https://github.com/mattwag05/pippin/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/mattwag05/pippin/compare/v0.2.1...v0.3.1
[0.2.1]: https://github.com/mattwag05/pippin/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mattwag05/pippin/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mattwag05/pippin/compare/v0.1.0-beta...v0.1.0
[0.1.0-beta]: https://github.com/mattwag05/pippin/releases/tag/v0.1.0-beta
