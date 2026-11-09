#!/usr/bin/env python3
"""paginated-emit lint.

Envelope v3 (pippin-37az) requires that a paginated command's agent `data` stay
the same TYPE as its unpaginated `data` — an array — with the cursor hoisted to
the envelope's top-level `next_cursor`. `AgentResult.page` / `.emitPage` do
that; handing a `Page` to the plain `AgentResult(...)` / `.emit` instead
re-nests `{items, next_cursor}` inside `data`, which is exactly the v2 bug that
made `for m in payload["data"]` iterate dict KEYS and silently yield the string
"items".

Why a lint rather than a type-level guard:
  - An `@available(*, unavailable)` `Page` overload does NOT win overload
    resolution (verified 2026-08-12): Swift prefers the available generic
    `some Encodable` one, so the mistake still compiles and the guard is dead
    code.
  - The CLI integration sweep can only assert on commands it can actually run,
    and every paginated command is permission-gated. Inside `swift test` just
    2 of 6 are reachable, so a regressed call site passed the sweep (verified).

Rule: in command sources, `.emit(page…)` / `AgentResult(page…)` is a violation:
use `.emitPage(…)` / `.page(…)`. A property of a page (`AgentResult(page.items…)`)
is not the page itself, so it passes.

Suppress a specific line with a trailing/preceding comment containing
`paginated-lint:allow` (document why).

Usage:
    lint-paginated-emit.py [paths...]      # default: pippin/Commands
    lint-paginated-emit.py --self-test     # run built-in fixtures
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_PATHS = ["pippin/Commands"]

ALLOW_MARKER = "paginated-lint:allow"

# `.emit(page` / `AgentResult(page`: any identifier whose name starts with `page`
# (page, pageOfNotes, page2…), so a renamed local still trips. `.emitPage` and
# `.page` are excluded by requiring the call paren to follow the bare name.
VIOLATION = re.compile(r"(?:\.(emit)|\b(AgentResult))\(\s*(page\w*)\b(?!\.)")


def strip_comments(source: str) -> str:
    """Blank out // and /* */ comments so a mention in prose never trips."""
    out = []
    i, n = 0, len(source)
    in_block = in_line = in_str = False
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if in_line:
            if ch == "\n":
                in_line = False
                out.append(ch)
            else:
                out.append(" ")
        elif in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
        elif in_str:
            out.append(ch)
            if ch == "\\":
                if i + 1 < n:
                    out.append(source[i + 1])
                    i += 2
                    continue
            elif ch == '"':
                in_str = False
        elif ch == "/" and nxt == "/":
            in_line = True
            out.append("  ")
            i += 2
            continue
        elif ch == "/" and nxt == "*":
            in_block = True
            out.append("  ")
            i += 2
            continue
        elif ch == '"':
            in_str = True
            out.append(ch)
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def check_source(source: str, path: str = "<memory>") -> list[str]:
    raw_lines = source.splitlines()
    lines = strip_comments(source).splitlines()
    violations = []
    for idx, line in enumerate(lines):
        match = VIOLATION.search(line)
        if not match:
            continue
        window = raw_lines[max(0, idx - 1) : idx + 2]
        if any(ALLOW_MARKER in w for w in window):
            continue
        method, arg = match.group(1) or match.group(2), match.group(3)
        fixed = ".emitPage" if method == "emit" else ".page"
        violations.append(
            f"{path}:{idx + 1}: `{method}({arg}…)` on a Page nests the cursor "
            f"inside `data` (envelope v2 shape) — use `{fixed}({arg}…)`."
        )
    return violations


def iter_swift_files(paths: list[str]):
    for entry in paths:
        p = Path(entry)
        if p.is_dir():
            yield from sorted(p.rglob("*.swift"))
        elif p.suffix == ".swift":
            yield p


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()
    paths = [a for a in argv[1:] if not a.startswith("-")] or DEFAULT_PATHS
    violations = []
    for file in iter_swift_files(paths):
        violations += check_source(file.read_text(), str(file))
    if violations:
        print("paginated-emit lint: violations found\n", file=sys.stderr)
        for v in violations:
            print(f"  {v}", file=sys.stderr)
        print(
            "\nSee docs/gotchas/swift.md § Paginated agent output (pippin-37az).",
            file=sys.stderr,
        )
        return 1
    print("paginated-emit lint: clean.")
    return 0


def _self_test() -> int:
    cases = [
        ("emitPage is fine", "return .emitPage(page, timedOut: t)\n", 0),
        ("page is fine", "return .page(page)\n", 0),
        ("bare emit on a page -> violation", "return .emit(page, timedOut: t)\n", 1),
        ("bare AgentResult on a page -> violation", "return AgentResult(page)\n", 1),
        ("renamed page local still trips", "return .emit(pageOfNotes)\n", 1),
        ("page property is fine", "AgentResult(page.items, nextCursor: c)\n", 0),
        ("non-page payload is fine", "return .emit(messages, timedOut: t)\n", 0),
        ("mention in a comment is ignored", "// never call .emit(page)\nreturn .emitPage(page)\n", 0),
        (
            "explicit allow marker suppresses",
            "// paginated-lint:allow: documented reason\nreturn .emit(page)\n",
            0,
        ),
    ]
    failures = 0
    for name, source, expected in cases:
        got = len(check_source(source))
        status = "PASS" if got == expected else "FAIL"
        if got != expected:
            failures += 1
        print(f"[{status}] {name}: expected {expected}, got {got}")
    if failures:
        print(f"\nself-test: {failures} failure(s).", file=sys.stderr)
        return 1
    print("\nself-test: all passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
