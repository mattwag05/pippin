#!/usr/bin/env python3
"""detach-blocking lint.

Caller-side `detachBlocking { ... }` is the convention for invoking sync,
thread-blocking bridge code from an `async` command (see
`pippin/DetachBlocking.swift` and `docs/gotchas/swift.md`). Without the hop,
`process.waitUntilExit()` / `DispatchSemaphore.wait()` /
`sendSynchronousRequest` stall a Swift cooperative thread — which wedges
`pippin mcp-server` under fan-out. There is no structural chokepoint to enforce
this (ScriptRunner is sync; ArgumentParser owns dispatch), so this lint is the
durable guard.

Rule: inside the body of a function declared `async`, a blocking call
(see BLOCKING_PATTERNS) is a violation unless it is lexically enclosed by a
`detachBlocking { }` closure. Blocking calls in *sync* functions are ignored —
they are wrapped at their async call site (or run in a genuinely sync context
such as the MCP read loop).

Suppress a specific line with a trailing/preceding comment containing
`detach-lint:allow` (document why).

Usage:
    lint-detach-blocking.py [paths...]      # default: pippin/Commands pippin/MCP
    lint-detach-blocking.py --self-test     # run built-in fixtures
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Blocking calls that must be hopped off the cooperative pool. Matched against
# the comment/string-stripped source, so substrings inside comments or string
# literals never trip the lint.
# Blocking entry points that must be hopped off the cooperative pool when
# called from async code. Scope is deliberately the genuinely-slow sync calls
# (seconds-to-minutes): osascript subprocesses, full contact-store scans, and
# synchronous network/semaphore waits.
#
# Intentionally NOT listed:
#   - VoiceMemosDB / GRDB SQLite reads: local, sub-millisecond — a different
#     risk class; wrapping them would be noise.
#   - RemindersBridge / CalendarBridge (EventKit): their public methods are
#     already `async`, so call sites are awaited, not sync-blocking. Their
#     internal synchronous wait is tracked separately in pippin-91n.
BLOCKING_PATTERNS = [
    # MailBridge.(read|list|search)*: readMessage / listMessages / listActivity
    # / listAccounts / listMailboxes / searchMessages — all shell out to a
    # blocking osascript subprocess via ScriptRunner.
    r"MailBridge\s*\.\s*(?:read|list|search)[A-Za-z0-9_]*\b",
    # NotesBridge: JXA osascript subprocesses (notes/folders enumeration).
    r"NotesBridge\s*\.\s*(?:read|list|search|show|count|create|edit|delete|append)[A-Za-z0-9_]*\b",
    # ContactsBridge: synchronous CNContactStore enumeration / CNSaveRequest.
    r"ContactsBridge\s*\.\s*(?:read|list|search|show|create)[A-Za-z0-9_]*\b",
    r"MCPServerRuntime\s*\.\s*runChild\b",
    r"\bsendSynchronousRequest\s*\(",
    r"\bDispatchSemaphore\s*\(",
]
_BLOCKING_RE = re.compile("|".join(BLOCKING_PATTERNS))

SUPPRESS_MARKER = "detach-lint:allow"

DEFAULT_PATHS = ["pippin/Commands", "pippin/MCP"]


def _strip_comments_and_strings(src: str) -> str:
    """Replace string-literal and comment content with spaces, preserving
    newlines and overall length so line/column offsets stay aligned. Braces
    and identifiers in code survive; everything quoted or commented becomes
    whitespace."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        # Line comment
        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        # Block comment
        if c == "/" and nxt == "*":
            out.append("  ")
            i += 2
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("  ")
                i += 2
            continue
        # Multiline string literal """ ... """
        if c == '"' and src[i : i + 3] == '"""':
            out.append("   ")
            i += 3
            while i < n and src[i : i + 3] != '"""':
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("   ")
                i += 3
            continue
        # Single-line string literal
        if c == '"':
            out.append(" ")
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append(" ")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


# Token: identifier, or one of the structural single chars we track.
_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[{}()]")


class _Frame:
    __slots__ = ("is_func", "is_async", "is_detach")

    def __init__(self, is_func: bool, is_async: bool, is_detach: bool):
        self.is_func = is_func
        self.is_async = is_async
        self.is_detach = is_detach


def lint_source(src: str, filename: str = "<src>") -> list[tuple[int, str]]:
    """Return a list of (line_number, matched_text) violations."""
    stripped = _strip_comments_and_strings(src)
    lines = src.splitlines()

    # Precompute line number for any character offset.
    line_starts = [0]
    for ch in src:
        line_starts.append(line_starts[-1] + 1)
    # offset -> line via bisect-like scan using newline positions
    newline_offsets = [m.start() for m in re.finditer("\n", src)]

    def offset_to_line(off: int) -> int:
        # 1-based line number
        lo, hi = 0, len(newline_offsets)
        while lo < hi:
            mid = (lo + hi) // 2
            if newline_offsets[mid] < off:
                lo = mid + 1
            else:
                hi = mid
        return lo + 1

    violations: list[tuple[int, str]] = []

    # Blocking-call offsets, so we can evaluate the brace stack *as of that
    # point* (handles same-line `detachBlocking { call }`).
    blocking_hits = {m.start(): m.group(0) for m in _BLOCKING_RE.finditer(stripped)}

    # Walk tokens, maintaining the brace stack; snapshot it at each blocking hit.
    stack: list[_Frame] = []
    scanning_func = False  # inside a func signature, before its body `{`
    func_is_async = False
    pending_detach = False  # next `{` opens a detachBlocking closure
    sorted_hits = sorted(blocking_hits.items())
    hit_idx = 0

    def in_async() -> bool:
        for fr in reversed(stack):
            if fr.is_func:
                return fr.is_async
        return False

    def covered() -> bool:
        return any(fr.is_detach for fr in stack)

    for m in _TOKEN_RE.finditer(stripped):
        tok = m.group(0)
        start = m.start()

        # Process any blocking hits at or before this token position.
        while hit_idx < len(sorted_hits) and sorted_hits[hit_idx][0] <= start:
            off, text = sorted_hits[hit_idx]
            if in_async() and not covered():
                ln = offset_to_line(off)
                if not _suppressed(lines, ln):
                    violations.append((ln, text.strip()))
            hit_idx += 1

        if tok == "func":
            scanning_func = True
            func_is_async = False
        elif scanning_func and tok == "async":
            func_is_async = True
        elif tok == "detachBlocking":
            pending_detach = True
        elif tok == "{":
            if scanning_func:
                stack.append(_Frame(True, func_is_async, False))
                scanning_func = False
                func_is_async = False
            elif pending_detach:
                stack.append(_Frame(False, False, True))
                pending_detach = False
            else:
                stack.append(_Frame(False, False, False))
        elif tok == "}":
            if stack:
                stack.pop()

    # Trailing hits after the last token (unlikely).
    while hit_idx < len(sorted_hits):
        off, text = sorted_hits[hit_idx]
        if in_async() and not covered():
            ln = offset_to_line(off)
            if not _suppressed(lines, ln):
                violations.append((ln, text.strip()))
        hit_idx += 1

    return violations


def _suppressed(lines: list[str], line_no: int) -> bool:
    """A violation is suppressed if its line or the immediately preceding line
    carries the SUPPRESS_MARKER."""
    for ln in (line_no, line_no - 1):
        if 1 <= ln <= len(lines) and SUPPRESS_MARKER in lines[ln - 1]:
            return True
    return False


def _iter_swift_files(paths: list[str]):
    for p in paths:
        path = Path(p)
        if path.is_dir():
            yield from sorted(path.rglob("*.swift"))
        elif path.suffix == ".swift":
            yield path


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()

    paths = [a for a in argv[1:] if not a.startswith("-")] or DEFAULT_PATHS
    total = 0
    for f in _iter_swift_files(paths):
        try:
            src = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, text in lint_source(src, str(f)):
            total += 1
            print(f"{f}:{line_no}: blocking call `{text}` in async code not "
                  f"inside detachBlocking {{ }} (wrap it, or add "
                  f"`{SUPPRESS_MARKER} <reason>`)")
    if total:
        print(f"\ndetach-blocking lint: {total} violation(s).", file=sys.stderr)
        return 1
    print("detach-blocking lint: clean.")
    return 0


def _self_test() -> int:
    cases = [
        # (source, expected_violation_count, label)
        (
            """
            func run() async throws {
                let x = try MailBridge.searchMessages(query: "a")
            }
            """,
            1,
            "bare bridge call in async func -> violation",
        ),
        (
            """
            func run() async throws {
                let x = try await detachBlocking { try MailBridge.searchMessages(query: "a") }
            }
            """,
            0,
            "same-line detachBlocking wrap -> ok",
        ),
        (
            """
            func run() async throws {
                let x = try await detachBlocking {
                    try MailBridge.listMessages(limit: 1)
                }
            }
            """,
            0,
            "multi-line detachBlocking wrap -> ok",
        ),
        (
            """
            func helper() -> Int {
                _ = try? MailBridge.listMessages(limit: 1)
                return 0
            }
            """,
            0,
            "bare bridge call in SYNC func -> ignored",
        ),
        (
            """
            func run() async throws {
                // MailBridge.searchMessages in a comment must not trip
                let s = "call MailBridge.searchMessages here"
                _ = try await detachBlocking { try MailBridge.readMessage(compoundId: "x") }
            }
            """,
            0,
            "comment/string mentions ignored",
        ),
        (
            """
            func run() async throws {
                let x = try MailBridge.searchMessages(query: "a") // detach-lint:allow probe
            }
            """,
            0,
            "suppression marker -> ignored",
        ),
        (
            """
            func run() async throws {
                let c = try MCPServerRuntime.runChild(argv: a)
            }
            """,
            1,
            "runChild bare in async -> violation",
        ),
        (
            """
            func outer() async throws {
                let items = [1, 2].map { _ in
                    try? MailBridge.listMessages(limit: 1)
                }
            }
            """,
            1,
            "bare call inside non-detach closure in async func -> violation",
        ),
        (
            """
            func run() async throws {
                let outcome = try NotesBridge.listNotes(limit: 5)
            }
            """,
            1,
            "bare NotesBridge.listNotes in async -> violation",
        ),
        (
            """
            func run() async throws {
                let outcome = try ContactsBridge.listContacts(group: g)
            }
            """,
            1,
            "bare ContactsBridge.listContacts in async -> violation",
        ),
        (
            """
            func run() async throws {
                let o = try await detachBlocking { try NotesBridge.listNotes(limit: 5) }
            }
            """,
            0,
            "wrapped NotesBridge call -> ok",
        ),
        (
            """
            func run() throws {
                let o = try NotesBridge.listNotes(limit: 5)
            }
            """,
            0,
            "NotesBridge call in SYNC command (like NotesCommand) -> ignored",
        ),
    ]
    failures = 0
    for src, expected, label in cases:
        got = len(lint_source(src))
        ok = got == expected
        print(f"[{'PASS' if ok else 'FAIL'}] {label}: expected {expected}, got {got}")
        if not ok:
            failures += 1
    if failures:
        print(f"\nself-test: {failures} failure(s).", file=sys.stderr)
        return 1
    print("\nself-test: all passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
