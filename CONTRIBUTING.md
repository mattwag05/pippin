# Contributing to pippin

## Dev setup

You need an arm64 Mac on macOS 15 or later, Xcode 16 or later, and [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (`brew install swiftformat`).

```bash
git clone https://github.com/mattwag05/pippin.git
cd pippin
make build
```

`make install` builds and copies the binary to `~/.local/bin/pippin`. Run `pippin permissions` once to grant access to the Apple apps. Grants persist across rebuilds only when the binary is signed with a stable identity.

## Test commands

| Command | What it does |
|---|---|
| `make test` | Unit and integration tests |
| `make ci` | Release build, tests, SwiftFormat lint and the repo lint scripts. Run this before opening a PR |
| `make e2e` | Read-only smoke test of the installed binary against your real Apple apps. Run it when you change Apple-app behavior |

Tests that need a permission or service your machine lacks skip themselves.

## Pull requests

- Keep each PR to one change, and add a test for new logic.
- Write commit subjects as Conventional Commits: `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `chore:`. Mark breaking changes with `!`, as in `feat!:`.
- Add user-visible changes to the `[Unreleased]` section of `CHANGELOG.md`.
- Every command returns an `AgentResult` and never prints to stdout. Every error needs an authored `next_step`. See `docs/gotchas/swift.md` and `docs/mcp-server.md`.
- Do not include real mail, messages, contacts or other personal data in tests, logs or screenshots.

This GitHub repository is a one-way mirror, so a PR cannot be merged here directly. Open it anyway: the maintainer applies accepted changes to the primary repository, and they appear here on the next sync.
