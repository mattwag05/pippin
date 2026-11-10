"""Shared plumbing for the competitive harness: MCP stdio client, CLI runner,
timing statistics and the environment record. Standard library only, so the
harness runs from a clean checkout with the system Python.

Nothing here knows about any particular tool. Per-tool knowledge lives in
adapters/*.py.
"""

from __future__ import annotations

import json
import os
import platform
import queue
import subprocess
import threading
import time

CALL_CEILING_S = 60.0  # methodology: a call past this is a hang and is killed


class ToolError(Exception):
    """The tool answered, and the answer was an error."""


class ToolHang(Exception):
    """The tool did not answer inside the ceiling and was killed."""


class McpSession:
    """Minimal MCP client over stdio (newline-delimited JSON-RPC 2.0)."""

    def __init__(self, command: list[str], cwd: str | None = None, env: dict | None = None):
        self.command = command
        self.proc = subprocess.Popen(
            command,
            cwd=cwd,
            env={**os.environ, **(env or {})},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self._next_id = 0
        self._lines: queue.Queue = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for raw in self.proc.stdout:
            self._lines.put(raw)
        self._lines.put(None)

    def _request(self, method: str, params: dict, timeout: float = CALL_CEILING_S) -> dict:
        self._next_id += 1
        rid = self._next_id
        msg = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.close(kill=True)
                raise ToolHang(f"{method} exceeded {timeout:.0f}s")
            try:
                raw = self._lines.get(timeout=remaining)
            except queue.Empty:
                continue
            if raw is None:
                raise ToolError(f"server exited during {method}")
            try:
                reply = json.loads(raw)
            except ValueError:
                continue  # servers that log to stdout: skip non-JSON lines
            if reply.get("id") != rid:
                continue  # notification or unrelated reply
            if "error" in reply:
                raise ToolError(json.dumps(reply["error"])[:500])
            return reply.get("result", {})

    def initialize(self) -> dict:
        result = self._request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "pippin-bench", "version": "1"},
            },
        )
        note = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        self.proc.stdin.write((json.dumps(note) + "\n").encode())
        self.proc.stdin.flush()
        return result

    def list_tools(self) -> list[dict]:
        tools, cursor = [], None
        while True:
            result = self._request("tools/list", {"cursor": cursor} if cursor else {})
            tools += result.get("tools", [])
            cursor = result.get("nextCursor")
            if not cursor:
                return tools

    def call(self, name: str, arguments: dict) -> str:
        """Returns the concatenated text content. Raises ToolError on isError."""
        result = self._request("tools/call", {"name": name, "arguments": arguments})
        text = "".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            raise ToolError(text[:500])
        return text

    def close(self, kill: bool = False):
        try:
            if kill:
                self.proc.kill()
            else:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def run_cli(argv: list[str], cwd: str | None = None, env: dict | None = None) -> str:
    """Runs a CLI once. Raises ToolHang past the ceiling, ToolError on nonzero exit."""
    try:
        done = subprocess.run(
            argv,
            cwd=cwd,
            env={**os.environ, **(env or {})},
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=CALL_CEILING_S,
        )
    except subprocess.TimeoutExpired:
        raise ToolHang(f"{argv[0]} exceeded {CALL_CEILING_S:.0f}s")
    out = done.stdout.decode(errors="replace")
    if done.returncode != 0:
        raise ToolError(f"exit {done.returncode}: {(out or done.stderr.decode(errors='replace'))[:500]}")
    return out


def timed(fn):
    """Returns (milliseconds, outcome, value). outcome is ok, error or hang."""
    start = time.monotonic()
    try:
        value = fn()
        outcome = "ok"
    except ToolHang as e:
        value, outcome = str(e), "hang"
    except ToolError as e:
        value, outcome = str(e), "error"
    return (time.monotonic() - start) * 1000.0, outcome, value


def percentile(values: list[float], p: float) -> float | None:
    """Nearest-rank percentile on the sorted sample."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * p // 100))  # ceil without math import
    return ordered[int(rank) - 1]


def summarize(samples_ms: list[float]) -> dict:
    return {
        "n": len(samples_ms),
        "min_ms": round(min(samples_ms), 2) if samples_ms else None,
        "p50_ms": round(percentile(samples_ms, 50), 2) if samples_ms else None,
        "p95_ms": round(percentile(samples_ms, 95), 2) if samples_ms else None,
        "max_ms": round(max(samples_ms), 2) if samples_ms else None,
    }


def _sh(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, timeout=10).stdout.decode().strip()
    except Exception:
        return "unknown"


def environment() -> dict:
    return {
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "hardware_model": _sh(["sysctl", "-n", "hw.model"]),
        "chip": _sh(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "memory_bytes": _sh(["sysctl", "-n", "hw.memsize"]),
        "macos_version": _sh(["sw_vers", "-productVersion"]),
        "macos_build": _sh(["sw_vers", "-buildVersion"]),
        "python": platform.python_version(),
        "node": _sh(["node", "--version"]),
        "swift": _sh(["swift", "--version"]).splitlines()[0] if _sh(["swift", "--version"]) else "unknown",
        "methodology_commit": _sh(["git", "log", "-1", "--format=%H", "--", "docs/competitive/methodology.md"]),
    }


if __name__ == "__main__":
    # Self-check: percentile math, and the hang path against a process that never answers.
    assert percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50) == 5
    assert percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95) == 10
    assert percentile([], 50) is None
    assert summarize([10.0, 20.0, 30.0])["p50_ms"] == 20.0
    silent = McpSession(["/bin/cat"])  # echoes our request back: same id, no result
    assert silent.initialize() == {}
    silent.close()
    mute = McpSession(["/bin/sleep", "30"])
    ms, outcome, _ = timed(lambda: mute._request("ping", {}, timeout=0.5))
    assert outcome == "hang" and ms < 5000, (outcome, ms)
    ms, outcome, _ = timed(lambda: run_cli(["/usr/bin/false"]))
    assert outcome == "error"
    print("core self-check ok")
