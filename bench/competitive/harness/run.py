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
import importlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from core import McpSession, ToolError, ToolHang, environment, run_cli, summarize, timed  # noqa: E402

WARM_N, WARMUP_N, COLD_N, CONCURRENCY = 30, 3, 5, 8  # methodology: Reliability and Speed
FIXTURE_CHAT = "+15555550101"


def load_adapters(only: set[str] | None) -> list:
    sys.path.insert(0, ROOT)
    adapters = []
    for filename in sorted(os.listdir(os.path.join(ROOT, "adapters"))):
        if not filename.endswith(".py") or filename.startswith("_"):
            continue
        module = importlib.import_module("adapters." + filename[:-3])
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


def resolve(driver: Driver, ops: dict, state: dict) -> dict:
    """Fills {list_id}, {calendar_id} from the fixture state and {chat} from the
    tool's own chat listing. An op whose placeholder cannot be filled is dropped."""
    known = {
        "{list_id}": (state.get("reminder_list") or {}).get("id"),
        "{calendar_id}": (state.get("calendar") or {}).get("id"),
    }
    uses_chat = any("{chat}" in map(str, args.values()) for args in ops.values())
    if uses_chat and "messages.chats" in driver.adapter.OPS and "messages.chats" in getattr(driver.adapter, "PARSE", {}):
        _, outcome, text = timed(lambda: driver.call("messages.chats", {"limit": 20}))
        if outcome == "ok":
            chats = driver.adapter.PARSE["messages.chats"](text)
            match = [c for c in chats if FIXTURE_CHAT in json.dumps(c)] or chats
            if match:
                known["{chat}"] = match[0].get("id")
    out = {}
    for op, args in ops.items():
        filled = {k: known.get(v, v) if isinstance(v, str) and v.startswith("{") else v for k, v in args.items()}
        if any(v is None for v in filled.values()):
            continue
        out[op] = filled
    return out


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
        parse = getattr(driver.adapter, "PARSE", {}).get(op)
        shapes = set()
        for _, outcome, value in results:
            if outcome == "ok" and parse:
                try:  # compare parsed records, not raw text: raw replies carry timings
                    shapes.add(json.dumps(parse(value), sort_keys=True, ensure_ascii=False))
                except Exception:
                    shapes.add("unparsed")
        out["concurrency"][op] = {
            "ok": sum(1 for _, outcome, _ in results if outcome == "ok"),
            "of": CONCURRENCY,
            "distinct_record_sets": len(shapes) if parse else None,  # reads of fixed state should agree
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
    parser.add_argument("--state", default=os.path.expanduser("~/bench/state.json"))
    parser.add_argument("--only", default="")
    parser.add_argument("--stages", default="manifest,speed,reliability,coverage")
    options = parser.parse_args()

    with open(os.path.join(ROOT, "ops_args.json")) as handle:
        ops_args = json.load(handle)
    with open(options.state) as handle:
        state = json.load(handle)
    stages = set(options.stages.split(","))
    os.makedirs(options.out, exist_ok=True)
    with open(os.path.join(options.out, "environment.json"), "w") as handle:
        json.dump(environment(), handle, indent=2)

    for adapter in load_adapters(set(options.only.split(",")) if options.only else None):
        driver = Driver(adapter, options.tools_dir)
        record = {"tool": adapter.NAME, "version": adapter.VERSION, "kind": adapter.KIND, "apps": adapter.APPS}
        try:
            read_args = resolve(driver, ops_args["read"], state)
            if "manifest" in stages:
                record["manifest"] = stage_manifest(driver)
            if "speed" in stages or "coverage" in stages:
                record["speed"] = stage_speed(driver, read_args)
            if "reliability" in stages:
                record["reliability"] = stage_reliability(driver, read_args, ops_args["bad"])
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
