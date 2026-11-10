"""Head-to-head runner. One code path for every tool: the only per-tool
knowledge is the adapter module (see ../adapters and ../OPS.md).

    python3 harness/run.py --tools-dir ~/bench-tools --out results/<date> [--only pippin,remindctl] [--stages manifest,speed]

Stages (methodology axis in brackets):
    manifest     [ergonomics]  size and token cost of what an agent must load
    speed        [speed]       cold and warm latency per read operation
    reliability  [reliability] success and hang rate, 8-way concurrency, bad-input probes
    coverage     [coverage]    which canonical operations each tool exposes and which answered

Correctness and safety stages live in checks.py because they need the fixture manifest.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from core import McpSession, ToolError, ToolHang, environment, run_cli, summarize, timed  # noqa: E402

WARM_N, WARMUP_N, COLD_N, CONCURRENCY = 30, 3, 5, 8  # methodology: Reliability and Speed


def load_adapters(only: set[str] | None) -> list:
    adapters = []
    folder = os.path.join(ROOT, "adapters")
    for filename in sorted(os.listdir(folder)):
        if not filename.endswith(".py") or filename.startswith("_"):
            continue
        spec = importlib.util.spec_from_file_location("adapter_" + filename[:-3], os.path.join(folder, filename))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if only is None or module.NAME in only:
            adapters.append(module)
    return adapters


class Driver:
    """Runs canonical operations through one adapter. MCP tools keep one warm
    session unless a cold call is asked for; CLIs spawn per call either way."""

    def __init__(self, adapter, tools_dir: str):
        self.adapter = adapter
        self.tools_dir = tools_dir
        self.command = adapter.launch(tools_dir)
        self.session: McpSession | None = None

    def _open(self) -> McpSession:
        session = McpSession(self.command)
        session.initialize()
        return session

    def call(self, op: str, args: dict, cold: bool = False) -> str:
        built = self.adapter.OPS[op](args)
        if self.adapter.KIND == "cli":
            return run_cli(self.command + list(built))
        name, arguments = built
        if cold:
            session = self._open()
            try:
                return session.call(name, arguments)
            finally:
                session.close()
        if self.session is None or self.session.proc.poll() is not None:
            self.session = self._open()
        return self.session.call(name, arguments)

    def close(self):
        if self.session is not None:
            self.session.close()
            self.session = None


def token_count(text: str) -> int:
    """The one fixed tokenizer used for every tool: words and single punctuation marks."""
    return len(re.findall(r"\w+|[^\w\s]", text))


def stage_manifest(driver: Driver) -> dict:
    if driver.adapter.KIND != "mcp":
        ms, outcome, value = timed(lambda: run_cli(driver.command + ["--help"]))
        text = value if outcome == "ok" else ""
        return {"kind": "cli", "help_outcome": outcome, "help_chars": len(text), "help_tokens": token_count(text)}
    session = McpSession(driver.command)
    try:
        ms, outcome, value = timed(lambda: (session.initialize(), session.list_tools())[1])
    finally:
        session.close()
    if outcome != "ok":
        return {"kind": "mcp", "outcome": outcome, "detail": str(value)[:300]}
    text = json.dumps(value, ensure_ascii=False)
    described = sum(1 for t in value if (t.get("description") or "").strip())
    annotated = sum(1 for t in value if t.get("annotations"))
    return {
        "kind": "mcp",
        "outcome": "ok",
        "spawn_to_tools_ms": round(ms, 2),
        "tool_count": len(value),
        "manifest_chars": len(text),
        "manifest_tokens": token_count(text),
        "tools_with_description": described,
        "tools_with_annotations": annotated,
    }


def _samples(driver: Driver, op: str, args: dict, n: int, cold: bool) -> dict:
    times, outcomes = [], {"ok": 0, "error": 0, "hang": 0}
    first_error = None
    for _ in range(n):
        ms, outcome, value = timed(lambda: driver.call(op, args, cold=cold))
        outcomes[outcome] += 1
        if outcome == "ok":
            times.append(ms)
        elif first_error is None:
            first_error = str(value)[:300]
        if outcome == "hang":
            driver.close()
            break  # a hang costs 60 s; one is enough to record it
    result = {"runs": sum(outcomes.values()), "outcomes": outcomes, **summarize(times)}
    if first_error:
        result["first_error"] = first_error
    return result


def stage_speed(driver: Driver, read_args: dict) -> dict:
    out = {}
    for op, args in read_args.items():
        if op not in driver.adapter.OPS:
            continue
        cold = _samples(driver, op, args, COLD_N, cold=True)
        if cold["outcomes"]["ok"] == 0:
            out[op] = {"cold": cold, "warm": None}  # do not spend 30 runs on an op that cannot answer
            continue
        for _ in range(WARMUP_N):
            timed(lambda: driver.call(op, args))
        out[op] = {"cold": cold, "warm": _samples(driver, op, args, WARM_N, cold=False)}
    driver.close()
    return out


def stage_reliability(driver: Driver, read_args: dict, bad_args: dict) -> dict:
    out = {"concurrency": {}, "bad_input": {}}
    for op, args in read_args.items():
        if op not in driver.adapter.OPS:
            continue

        def one(_):
            worker = Driver(driver.adapter, driver.tools_dir)
            try:
                return timed(lambda: worker.call(op, args, cold=True))
            finally:
                worker.close()

        with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
            results = list(pool.map(one, range(CONCURRENCY)))
        texts = {value for _, outcome, value in results if outcome == "ok"}
        out["concurrency"][op] = {
            "ok": sum(1 for _, outcome, _ in results if outcome == "ok"),
            "of": CONCURRENCY,
            "distinct_outputs": len(texts),  # reads of fixed state should agree
        }
    for op, args in bad_args.items():
        if op not in driver.adapter.OPS:
            continue
        ms, outcome, value = timed(lambda: driver.call(op, args, cold=True))
        text = str(value)
        structured = False
        if outcome == "error":
            try:
                json.loads(text[text.index("{") :])
                structured = True
            except ValueError:
                structured = False
        out["bad_input"][op] = {
            # "ok" here means the tool reported success for an id that does not exist
            "outcome": outcome,
            "ms": round(ms, 2),
            "error_is_structured": structured,
            "detail": text[:200],
        }
    return out


def stage_coverage(driver: Driver, canonical_ops: list[str], speed: dict) -> dict:
    out = {}
    for op in canonical_ops:
        if op not in driver.adapter.OPS:
            out[op] = "no"
        elif op in speed:
            answered = speed[op]["cold"]["outcomes"]["ok"] > 0
            out[op] = "yes" if answered else "claimed"
        else:
            out[op] = "claimed"  # write operations are promoted to "yes" by checks.py probes
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tools-dir", default=os.path.expanduser("~/bench-tools"))
    parser.add_argument("--out", required=True)
    parser.add_argument("--only", default="")
    parser.add_argument("--stages", default="manifest,speed,reliability,coverage")
    options = parser.parse_args()

    with open(os.path.join(ROOT, "ops_args.json")) as handle:
        ops_args = json.load(handle)
    stages = set(options.stages.split(","))
    os.makedirs(options.out, exist_ok=True)
    with open(os.path.join(options.out, "environment.json"), "w") as handle:
        json.dump(environment(), handle, indent=2)

    for adapter in load_adapters(set(options.only.split(",")) if options.only else None):
        driver = Driver(adapter, options.tools_dir)
        record = {"tool": adapter.NAME, "version": adapter.VERSION, "kind": adapter.KIND, "apps": adapter.APPS}
        try:
            if "manifest" in stages:
                record["manifest"] = stage_manifest(driver)
            if "speed" in stages or "coverage" in stages:
                record["speed"] = stage_speed(driver, ops_args["read"])
            if "reliability" in stages:
                record["reliability"] = stage_reliability(driver, ops_args["read"], ops_args["bad"])
            if "coverage" in stages:
                record["coverage"] = stage_coverage(driver, ops_args["canonical"], record.get("speed", {}))
        except (ToolError, ToolHang, OSError) as error:
            record["not_run"] = str(error)[:300]  # methodology: not run is reported, never scored as a loss
        finally:
            driver.close()
        with open(os.path.join(options.out, adapter.NAME + ".json"), "w") as handle:
            json.dump(record, handle, indent=2, ensure_ascii=False)
        print(adapter.NAME, "done" if "not_run" not in record else "NOT RUN: " + record["not_run"], flush=True)


if __name__ == "__main__":
    main()
