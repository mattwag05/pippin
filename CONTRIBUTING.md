# Contributing to pippin

Pippin is a Swift 6 command-line tool and MCP server that lets AI agents automate Apple apps on macOS. Read [docs/architecture.md](docs/architecture.md) first if you are new to the code. The promises made to callers are in [docs/contract.md](docs/contract.md).

## Setup

You need an arm64 Mac on macOS 15 or later, Xcode 16 or later (the package declares `.macOS(.v15)`), and [SwiftFormat](https://github.com/nicklockwood/SwiftFormat).

```bash
brew install swiftformat
git clone https://github.com/mattwag05/pippin.git
cd pippin
make build
```

`make build` runs `xcrun --sdk macosx swift build -c release`. The binary is at `.build/release/pippin`.

`make install` builds, writes shell completions, signs the binary and copies it to `~/.local/bin/pippin`. Run `pippin permissions` once from a terminal to grant access to the Apple apps. macOS keeps a grant across rebuilds only if the binary is signed with a stable identity. `make install` calls `scripts/sign.sh`, which signs when it finds a signing identity and otherwise warns and leaves the build ad-hoc signed. See [docs/gotchas/permissions.md](docs/gotchas/permissions.md).

A debug build (`.build/debug/pippin`) has no permission grants. Argument-parsing and validation errors still work on it, which is enough to check many changes. Set `PIPPIN_NO_DISCLAIM=1` to skip the self-respawn when you run it by hand.

## Commands

| Command | What it does |
| --- | --- |
| `make build` | Release build. |
| `make test` | The whole test suite (`swift test`). |
| `make lint` | `swiftformat --lint pippin/ pippin-entry/ Tests/`. Reports; does not rewrite. |
| `make ci` | Release build, tests, SwiftFormat lint, and the two repo lint scripts. Run it before you open a PR. |
| `make e2e` | Read-only smoke test of the installed binary against your real Apple apps. Run it when you change Apple-app behavior. `E2E_RW=1 make e2e` adds write round-trips. |
| `make install` | Build, sign and install to `~/.local/bin/pippin`. |
| `make ci-vm` | The CI gate in a Tart macOS VM. Needs one-time setup; see [docs/local-ci.md](docs/local-ci.md). |

`make ci` runs these steps, which you can also run alone:

```bash
xcrun --sdk macosx swift build -c release
make test
swiftformat --lint pippin/ pippin-entry/ Tests/
python3 scripts/lint-detach-blocking.py --self-test
python3 scripts/lint-detach-blocking.py
python3 scripts/lint-paginated-emit.py --self-test
python3 scripts/lint-paginated-emit.py
```

`lint-detach-blocking.py` fails when an `async` function makes a blocking call (waiting on a process, a semaphore, a synchronous request) outside `detachBlocking { }`. `lint-paginated-emit.py` fails when a command hands a `Page` to `AgentResult(...)` or `.emit` instead of `.page` or `.emitPage`.

### Running one test

`swift test --filter` takes a class or a `Class/method` name:

```bash
xcrun --sdk macosx swift test --filter 'PippinTests.CursorTests'
xcrun --sdk macosx swift test --filter 'CLIMCPDriftTests/testEnumsMatchCLIAllowedValues'
```

If `xcode-select -p` points at the Command Line Tools, these fail with `no such module 'XCTest'`, because that SDK has no XCTest. `make test` detects this and re-runs under an installed Xcode on its own. For a single test, set `DEVELOPER_DIR` yourself:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun --sdk macosx swift test --filter 'PippinTests.CursorTests'
```

`scripts/test-suite.sh fuzz` and `scripts/test-suite.sh chaos` run the fuzz and chaos suites alone. A fuzz failure prints its seed. Replay it with `PIPPIN_FUZZ_SEED=<seed> scripts/test-suite.sh fuzz`.

Do not trust the tail of `swift test` output for the pass count. See [docs/gotchas/build.md](docs/gotchas/build.md).

## Branches and commits

- Work on a branch and open a pull request against `main`. Branch names in the history look like `claude/<topic>` or `docs/<topic>`. Use a short topic.
- Write commit subjects as Conventional Commits with an optional scope: `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `chore:`, `ci:`, `build:`. Examples from the log: `fix(mail): treat --after and --before as whole local days`, `docs(changelog): Mail and do fixes`. Mark a breaking change with `!`, as in `feat!:`.
- Keep each commit to one change. Put the reason in the body when the subject cannot carry it.
- Mention the Beads issue id (`pippin-xxxx`) in the commit body or the CHANGELOG line when there is one.
- A branch that groups several commits is merged with a `merge: <summary>` commit.

## The CHANGELOG rule

Every user-visible change adds one line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), in this form:

```
- [bug|feat|perf|test|docs] <user-facing effect>. Closes pippin-XXX.
```

- Pick one tag: `bug` for a fix, `feat` for new behavior, `perf` for speed, `test` for new test coverage that a user of the contract cares about, `docs` for documentation.
- State the effect on a user or an agent, not the code you changed. Write "`mail list --before` now includes its own day", not "fix off-by-one in dayFilterInstants".
- End with `Closes pippin-XXX.` when the change closes an issue, or `Refs pippin-XXX.` when it only touches one. Leave it off when there is no issue.
- Put the line in the subsection that matches the tag, as the neighbouring entries do: `### Added` for `feat`, `test` and `docs`, `### Fixed` for `bug`, `### Performance` for `perf`.
- Removing or renaming a tool, an argument, an envelope field or an error code is a breaking change. Read the semver and deprecation rules in [docs/contract.md](docs/contract.md) first.

Prose in the CHANGELOG, in docs and in comments uses plain sentences. Do not use em-dashes or en-dashes; use commas, colons or parentheses.

## Adding a command and its MCP tool

The ArgumentParser command is the single source. The MCP tool is a short spec that names the CLI arguments it exposes; its JSON Schema and argv are generated from the command's definition.

1. **Write the command** under `pippin/Commands/` (or a new bridge folder if it needs one). Conform to `AgentCommand`: an `@OptionGroup var output: OutputOptions` and `mutating func execute() async throws -> AgentResult`. Return the result; never print. Register the command in its parent group. A new top-level group also goes in the `subcommands` list in `pippin-entry/Pippin.swift` and in `MCPCommandRoot` in `pippin/MCP/ToolSpec.swift`. Give every option and flag an `abstract` help string: it becomes the MCP description unless the spec overrides it.
2. **Give each error an authored code and `next_step`.** Make the error type conform to `RemediableError` and set `agentCode` and `nextStep`. A paginated list returns its result with `AgentResult.page` or `emitPage`. See [docs/gotchas/swift.md](docs/gotchas/swift.md).
3. **Add the tool** to `specs` in `pippin/MCP/ToolRegistry.swift`:
   - `MCPToolSpec("<group>_<verb>", effect, "description", properties: [...])`. The tool name must map to the command path (`mail_apply_rules` is `mail apply-rules`). If it does not, add a `pathOverrides` entry in `MCPCommandPolicy`.
   - The effect is `.readOnly` or `.mutating(verifyWith: "<read tool>")`. The verify tool must be read-only and need no required arguments. A tool with no effect fails `ToolEffectTests`.
   - One `.arg("name", "--flag")` per property. Use `.positional` for an id and `.trailing` for free text (passed last after `--`). Add `as: .integer` or `as: .number` for a numeric option. Type, `enum`, required-ness, description and numeric default come from the CLI; pass a description, `required:` or `default:` only where the MCP contract differs.
   - Logic that is not one argument (a gate, alternatives, a value moved to another flag) is an `emit: .custom` closure or a `.special` property with its schema written out. Keep it small and add the property to `CLIMCPDriftTests.specialBindings` when it sets no CLI argument of its own type.
   - For a list or search tool, add its name to `projectableTools` (gives it `fields`) and, if it pages, to `pagedTools`.
4. **Run the drift tests and fix what they report.** `CLIMCPDriftTests` parses your argv with the real command and compares the tool's schema with the command's definition:
   - Every tool argument must set a CLI argument that exists, with a matching type, `enum` and required-ness. A wrong or missing `as: .integer` fails here.
   - Every CLI argument must be reachable from the tool, or be listed in `CLIMCPDriftTests.cliOnly` with a reason. An allowlist entry that is no longer needed also fails.
   - A tool argument that does not map to one option of the same JSON type goes in `CLIMCPDriftTests.specialBindings` with a reason.
   - A new top-level group must also be added to the `groups` map in `ToolRegistryTests.testAllArgvParseAsRealCLICommands`.
5. **Register the other expectations the tests pin:**
   - A mutating tool goes in the pinned set in `Tests/PippinTests/MCP/ToolEffectTests.swift`.
   - `InProcessToolsTests.testRegistryToolCount` holds the tool count as a literal. Update it.
   - Update the tool count and the tool table in `docs/mcp-server.md`, and the count in `README.md` if it states one.
6. **Describe the output.** Add the tool to `outputs` in `Tests/PippinTests/Contract/SchemaGoldenTests.swift` with the payload type, or add it to `noOutputSchema` with the reason it has none. A tool must be in exactly one of the two.
7. **Regenerate the schemas** (below) and commit the files under `docs/schemas/v4/` with your change.
8. **Add tests** for the new logic, and a CHANGELOG line.

### Regenerating the schemas

The files under [docs/schemas/v4/](docs/schemas/v4) (the input and output schemas for each tool, and `index.json`) are generated from the tool registry and the payload models. `SchemaGoldenTests` fails when they differ from what the code produces. After an intended change, run:

```bash
PIPPIN_UPDATE_SCHEMAS=1 make test
make test
```

The first run rewrites the files. The second confirms they are stable. Review the diff: in `docs/schemas/`, a removed or retyped line is a breaking change and an added optional one is additive. `envelope.schema.json` is edited by hand.

If you raise `AGENT_SCHEMA_VERSION`, the golden tests fail until a new `docs/schemas/v<N+1>/` directory exists. Keep the old directory as published.

## Test rules

- **Never touch real user data.** Tests must not read or write a real mailbox, message store, contact, calendar, note, reminder or voice memo. Use fakes: a temporary SQLite file shaped like the real schema (see `MessagesFixture` in `Tests/PippinTests/MessagesTestSupport.swift`), injected closures for the app launcher, the running-app check and the Trash, and fake AI providers.
- **Test generated JXA in JavaScriptCore against a fake app object**, as `NotesScriptBehaviorTests` does. Assert what the script does, not what its text looks like.
- **Use temporary directories** for caches and job stores. Remove them in `tearDown`.
- A test that needs a permission or a service the machine lacks must skip itself with `XCTSkip`, not fail.
- No real mail, messages, contacts, names, phone numbers or other personal data in tests, fixtures, logs or screenshots. Use invented values.
- A new `async` bridge call that blocks must go through `detachBlocking`. `make ci` checks this.
- Do not commit `.env` files, keys or tokens. A CI gitleaks job scans the history for them.
- `make e2e` is the only place real apps are touched. It is read-only unless you set `E2E_RW=1`, and a human runs it.

## Issue tracking with Beads

Open issues are tracked with Beads (`bd`) in the `.beads/` directory. If you use it:

```bash
bd ready                     # work with no blockers
bd show <id>                 # details
bd update <id> --claim       # take an issue
bd create "title"            # file an out-of-scope bug or debt you found
bd close <id>                # when the work is merged
```

Issue ids look like `pippin-xxxx`. Use them in commit bodies and CHANGELOG lines. If you file work you are not doing, create an issue for it instead of leaving a comment in the code. You do not need `bd` to send a pull request.

## Pull requests

- One change per PR, with a test for new logic.
- Run `make ci` and make sure it passes.
- Every command returns an `AgentResult` and never prints to stdout. Every error needs an authored `next_step`. See [docs/gotchas/swift.md](docs/gotchas/swift.md) and [docs/mcp-server.md](docs/mcp-server.md).
- Add the CHANGELOG line.

## Pushes and releases

Pushes to the shared repository and releases need the maintainer's approval. Do not push to `main`, tag a version, or publish a release yourself. The release steps (version bump, tag, signed tarball, Homebrew tap update) are in [docs/skills/release](docs/skills/release) and are run by the maintainer.

The GitHub repository is a one-way mirror of the primary repository, so a pull request opened on GitHub cannot be merged there directly. Open it anyway. The maintainer applies accepted changes to the primary repository, and they appear on GitHub at the next sync.
