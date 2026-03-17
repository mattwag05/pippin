# Pippin Autonomous Audit & Improve

/autonomous-execution follow these guidelines to continuously build and improve upon Pippin.

## Mission

Conduct a comprehensive autonomous audit and improvement pass on the Pippin codebase — a macOS CLI toolkit (Swift 6, SPM) with 8 bridge modules for Apple app automation. Research the current state, identify issues, implement fixes, and deliver a structured changelog entry.

## Phase 1 — Reconnaissance

Before making any changes:

1. Read `CLAUDE.md`, `CHANGELOG.md`, and `README.md`
2. Run `make version` to confirm the current version
3. Map the bridge modules: `pippin/{Mail,Memos,Calendar,Audio,Contacts,Browser,Reminders,Notes}Bridge/`
4. Read `pippin/Commands/OutputOptions.swift` and `pippin/Formatting/AgentOutput.swift` to understand the output format contract
5. Run `make test` to establish a passing baseline (831+ tests expected)
6. Run `make lint` to check formatting baseline
7. Check for open issues: `bd ready` (if beads is configured; skip if `bd` is not available)
8. Read `docs/` for any active specs or design documents

## Phase 2 — Audit

Work through each category. For each finding, note the file, line, and severity.

### Security
- Hardcoded secrets, leaked API keys, unsafe deserialization
- JXA script injection (user input interpolated into osascript strings without escaping)
- File path traversal in export/attachment paths

### Bugs
- Logic errors, unhandled edge cases, broken flows
- JXA script builder correctness (test by reading generated script strings)
- EventKit permission handling gaps
- Compound ID parsing edge cases (`account||mailbox||numericId`)

### AX (Agent Experience)
- Commands missing `--format agent` support or with broken agent output
- Agent output that isn't compact JSON (must use `printAgentJSON`, not `printJSON`)
- Progress `print()` calls not guarded by `!outputOptions.isStructured`
- Action results not following the three-way pattern: `isJSON -> printJSON`, `isAgent -> printAgentJSON`, else text
- Missing `debugDetail` on bridge error types

### Bridge Consistency
- Bridges not following the established pattern: `enum` with `static` methods, `nonisolated(unsafe)` vars, DispatchGroup concurrent pipe drain, DispatchWorkItem SIGTERM->SIGKILL timeout
- Inconsistent error types across bridges (each bridge should have a typed error enum with `LocalizedError` conformance)
- Missing or inconsistent `runScript` implementations

### Code Quality
- Dead code, duplicated logic, overly complex functions
- `TextFormatter.actionResult` dict overload not used (hand-rolled inline formatting)
- Shared validation helpers not reused across similar commands
- GRDB `SQL` type inference traps (missing explicit type annotations)

### Test Coverage
- Bridge modules without corresponding test files
- Commands without parse/validate tests
- Missing edge case tests for compound ID parsing, date range handling, JXA escaping

### Dependency Hygiene
- Outdated packages in `Package.resolved`
- Unused imports

## Phase 3 — Fix

For each issue found, in priority order:

1. **Security** — fix immediately
2. **Bugs** — fix
3. **AX gaps** — fix (this is Pippin's primary consumer interface)
4. **Bridge consistency** — fix if the inconsistency causes real problems
5. **Code quality** — fix only clear wins (dead code, obvious duplication)
6. **Test coverage** — add missing tests

After each fix:
- Run `make test` — all 831+ tests must pass
- Run `make lint` — no formatting violations
- Verify `swift build -c release` succeeds

**Do NOT:**
- Modify `.env`, secrets, or `Package.resolved` without cause
- Change external API contracts (CLI argument names, JSON output shapes)
- Add comments about `nonisolated(unsafe)` — the pattern is intentional for Swift 6 strict concurrency
- Remove or rename public API without checking all call sites
- Add typed error cases for JXA failures (they always arrive as `scriptFailed(String)`)

## Phase 4 — Feature Development

If no Security, Bug, or AX findings remain unresolved:

1. Check `bd ready` for prioritized issues (if beads is available)
2. If no beads issues, analyze the codebase for the highest-value improvement:
   - Missing subcommand that would complete a bridge's functionality
   - Bridge that lacks `--format agent` support on a subcommand
   - Test coverage gaps in critical paths
   - Cross-bridge features (e.g., shared validation, unified error reporting)
3. Read any relevant spec in `docs/superpowers/specs/` before implementing
4. Implement fully: logic, integration, and tests
5. Validate end-to-end: `make test`, `make lint`, `make build`

## Phase 5 — Changelog & Report

Append a structured entry to `CHANGELOG.md` following the existing Keep a Changelog format:

```
## [Unreleased]

### Fixed
- [security] file.swift: description of problem and fix
- [bug] file.swift: description

### Changed
- [ax] file.swift: description
- [quality] file.swift: description

### Added
- [feature] file.swift: description
- [test] TestFile.swift: description
```

Output a terminal summary:
- Total issues found by category
- Total fixed
- Any deferred items with reason
- Test count before and after
- `make test` / `make lint` / `make build` final status

## Constraints
- Do NOT delete files or modify secrets/credentials
- Do NOT change CLI argument names or JSON output shapes (breaking changes)
- Do NOT bump the version — that's a separate release step
- If a fix has high regression risk, document it as "Recommended Manual Fix" in the changelog instead of applying it
- If you hit an obstacle, diagnose and work around it — do not stop and ask until you've exhausted alternatives
