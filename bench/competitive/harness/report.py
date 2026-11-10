"""Turns a results directory into the tables used in docs/competitive/results.md.

    python3 harness/report.py results/<date> > results/<date>/summary.md

Only arithmetic on the raw JSON written by run.py, checks.py and tasks.py. The rubric
and tie rule are the ones in docs/competitive/methodology.md. Mail and Voice Memos are
"not run" for every tool (methodology amendment 1), so they are left out of every score.
"""

from __future__ import annotations

import glob
import json
import os
import statistics
import sys

NOT_RUN_APPS = {"mail", "memos"}
PROBED_WRITES = {"create", "delete"}  # edit, complete, show and send are not probed: shown as claimed, not scored


def load(directory: str) -> dict:
    tools = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        name = os.path.basename(path)
        if name in ("environment.json", "scores.json"):
            continue
        with open(path) as handle:
            data = json.load(handle)
        tools.setdefault(data["tool"], {}).update(data)
    for path in sorted(glob.glob(os.path.join(directory, "tasks", "*.tasks.json"))):
        with open(path) as handle:
            data = json.load(handle)
        tools.setdefault(data["tool"], {})["tasks"] = data
    return tools


def rubric(failed: int, total: int):
    if total == 0:
        return None
    share = failed / total
    return 4 if failed == 0 else 3 if share <= 0.10 else 2 if share <= 0.40 else 1


def ran(tool: dict) -> bool:
    return bool(tool.get("speed")) and "not_run" not in tool and bool(scored_apps(tool))


def scored_apps(tool: dict) -> list:
    return [a for a in tool.get("apps", []) if a not in NOT_RUN_APPS]


def coverage(tool: dict) -> dict:
    """app -> (yes, probed cells). A write is yes only when its probe round-tripped."""
    cells = dict(tool.get("coverage", {}))
    for domain, labels in (tool.get("writes") or {}).items():
        plain = labels.get("plain", {})
        if plain.get("create") == "ok" and plain.get("read_back"):
            cells[domain + ".create"] = "yes"
        if plain.get("delete") == "ok" and plain.get("gone"):
            cells[domain + ".delete"] = "yes"
    out = {}
    for app in scored_apps(tool):
        probed = {op: v for op, v in cells.items() if op.startswith(app + ".") and (op in tool.get("speed", {}) or op.split(".")[1] in PROBED_WRITES or v == "no")}
        out[app] = (sum(1 for v in probed.values() if v == "yes"), len(probed))
    return out


def correctness(tool: dict) -> tuple:
    failed, total, notes = 0, 0, []
    for op, result in (tool.get("correctness") or {}).items():
        if op == "messages.chats":
            for key, chat in result.get("chats", {}).items():
                if chat["reported_unread"] is not None:
                    total += 1
                    if chat["reported_unread"] != chat["expected_unread"]:
                        failed += 1
                        notes.append("%s unread %s, expected %s" % (key, chat["reported_unread"], chat["expected_unread"]))
            continue
        if result.get("outcome") == "not_machine_readable":
            notes.append("%s: reply is prose, not checked" % op)
            continue
        if result.get("outcome") != "ok":
            total, failed = total + 1, failed + 1
            notes.append("%s: %s" % (op, result.get("outcome")))
            continue
        checks = {"missing": result["missing"], "unexpected": result["unexpected"], "duplicated": result["duplicated"]}
        if "dates" in result:
            checks["wrong instant"] = result["dates"]["wrong"]
        if result.get("outgoing_with_recipient_as_sender"):
            checks["outgoing sender wrong"] = [result["outgoing_with_recipient_as_sender"]]
        for label, bad in checks.items():
            total += 1
            if bad:
                failed += 1
                notes.append("%s: %d %s" % (op, len(bad) if label != "outgoing sender wrong" else bad[0], label))
    for domain, labels in (tool.get("writes") or {}).items():
        for label, step in labels.items():
            if step.get("read_back"):
                total += 1
                if not step.get("title_exact"):
                    failed += 1
                    notes.append("%s create: %s title changed" % (domain, label))
    return failed, total, notes


def reliability(tool: dict) -> tuple:
    failed, total, notes = 0, 0, []
    for op, sample in (tool.get("speed") or {}).items():
        app = op.split(".")[0]
        if app in NOT_RUN_APPS:
            continue
        for phase in ("cold", "warm"):
            runs = sample.get(phase)
            if not runs:
                continue
            total += 1
            if runs["outcomes"]["ok"] != runs["runs"]:
                failed += 1
                notes.append("%s %s: %s" % (op, phase, runs["outcomes"]))
    for op, result in (tool.get("reliability") or {}).get("concurrency", {}).items():
        if op.split(".")[0] in NOT_RUN_APPS:
            continue
        total += 1
        if result["ok"] != result["of"] or (result.get("distinct_record_sets") or 1) > 1:
            failed += 1
            notes.append("%s x8: %d ok, %s distinct" % (op, result["ok"], result.get("distinct_record_sets")))
    for op, result in (tool.get("reliability") or {}).get("bad_input", {}).items():
        total += 1
        if result["outcome"] != "error":
            failed += 1
            notes.append("%s bad input: %s" % (op, "reported success" if result["outcome"] == "ok" else result["outcome"]))
    return failed, total, notes


def safety(tool: dict) -> tuple:
    block = tool.get("safety") or {}
    if "items" not in block:
        return 0, 0, [block.get("not_run", "not run")], False
    failed, total, notes = 0, 0, []
    executed = bool(block["canary_created"]) or any(step.get("canary_created") for labels in (tool.get("writes") or {}).values() for step in labels.values())
    for key, item in block["items"].items():
        for op, outcome in item["outcomes"].items():
            total += 1
            if outcome == "hang":
                failed += 1
                notes.append("%s on %s: hang" % (item["class"], op))
    for op, outcome in block["alive_after"].items():
        total += 1
        if outcome != "ok":
            failed += 1
            notes.append("%s did not answer after the hostile inputs" % op)
    if executed:
        notes.append("DEALBREAKER: a hostile string was executed")
    return failed, total, notes, executed


def speed_table(tools: dict) -> tuple:
    """op -> {tool: warm p50}, and per tool the list of per-op rubric scores."""
    table, scores = {}, {name: [] for name in tools}
    ops = sorted({op for t in tools.values() for op in (t.get("speed") or {}) if op.split(".")[0] not in NOT_RUN_APPS})
    for op in ops:
        row = {name: t["speed"][op]["warm"]["p50_ms"] for name, t in tools.items() if (t.get("speed") or {}).get(op, {}).get("warm") and t["speed"][op]["warm"].get("p50_ms") is not None}
        if not row:
            continue
        table[op] = row
        best = min(row.values())
        for name, value in row.items():
            tie = value - best <= max(0.10 * best, 20.0)
            scores[name].append(4 if value == best else 3 if tie else 2 if value <= 3 * best else 1)
    return table, scores


def main():
    directory = sys.argv[1]
    tools = load(directory)
    names = [n for n in tools if ran(tools[n])]
    skipped = [n for n in tools if not ran(tools[n])]
    table, speed_scores = speed_table({n: tools[n] for n in names})
    scores = {}
    out = []

    out.append("## Scores (0 to 4, rubric in methodology.md)\n")
    out.append("| Tool | Version | Apps scored | Coverage | Correctness | Reliability | Speed | Safety (input) | Dealbreaker |")
    out.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    detail = {}
    for name in names:
        tool = tools[name]
        cov = coverage(tool)
        yes, cells = sum(v[0] for v in cov.values()), sum(v[1] for v in cov.values())
        c_failed, c_total, c_notes = correctness(tool)
        r_failed, r_total, r_notes = reliability(tool)
        s_failed, s_total, s_notes, executed = safety(tool)
        speed = round(statistics.mean(speed_scores[name])) if speed_scores[name] else None
        scores[name] = {
            "coverage": rubric(cells - yes, cells), "coverage_cells": [yes, cells], "apps": len(cov),
            "correctness": rubric(c_failed, c_total), "correctness_checks": [c_total - c_failed, c_total],
            "reliability": rubric(r_failed, r_total), "reliability_checks": [r_total - r_failed, r_total],
            "speed": speed, "safety_input": 0 if executed else rubric(s_failed, s_total), "safety_checks": [s_total - s_failed, s_total],
            "dealbreaker": executed,
        }
        detail[name] = {"correctness": c_notes, "reliability": r_notes, "safety": s_notes}
        s = scores[name]
        show = lambda key, pair: "n/r" if s[key] is None else "%d (%d/%d)" % (s[key], pair[0], pair[1])
        out.append("| %s | %s | %d | %s | %s | %s | %s | %s | %s |" % (
            name, tool.get("version", ""), len(cov), show("coverage", s["coverage_cells"]), show("correctness", s["correctness_checks"]),
            show("reliability", s["reliability_checks"]), "n/r" if speed is None else speed, show("safety_input", s["safety_checks"]), "yes" if executed else "none observed"))
    for name in skipped:
        reason = tools[name].get("not_run") or ("Mail only, and the VM has no mail account" if tools[name].get("apps") and not scored_apps(tools[name]) else None) or (tools[name].get("manifest") or {}).get("detail") or "no operation could be driven"
        out.append("| %s | %s | n/r | n/r | n/r | n/r | n/r | n/r | not run: %s |" % (name, tools[name].get("version", ""), reason))

    out.append("\n## Coverage by app (yes / probed cells)\n")
    apps = ["reminders", "calendar", "contacts", "notes", "messages"]
    out.append("| Tool | " + " | ".join(apps) + " |")
    out.append("| --- |" + " --- |" * len(apps))
    for name in names:
        cov = coverage(tools[name])
        out.append("| %s | %s |" % (name, " | ".join("%d/%d" % cov[a] if a in cov else "out of scope" for a in apps)))

    out.append("\n## Warm latency, p50 in ms (N = 30 after 3 warmups)\n")
    out.append("| Operation | " + " | ".join(names) + " |")
    out.append("| --- |" + " --- |" * len(names))
    for op, row in table.items():
        best = min(row.values())
        out.append("| %s | %s |" % (op, " | ".join(("**%.1f**" if row[n] == best else "%.1f") % row[n] if n in row else "" for n in names)))

    out.append("\n## Cold latency, p50 in ms (N = 5, new process per call)\n")
    out.append("| Operation | " + " | ".join(names) + " |")
    out.append("| --- |" + " --- |" * len(names))
    for op in table:
        out.append("| %s | %s |" % (op, " | ".join("%.1f" % tools[n]["speed"][op]["cold"]["p50_ms"] if op in tools[n]["speed"] and tools[n]["speed"][op]["cold"].get("p50_ms") is not None else "" for n in names)))

    out.append("\n## Agent ergonomics (raw)\n")
    out.append("| Tool | Kind | Tools | Manifest tokens | Tools with behavior annotations | Structured errors on bad input |")
    out.append("| --- | --- | --- | --- | --- | --- |")
    for name in names:
        m = tools[name].get("manifest", {})
        bad = (tools[name].get("reliability") or {}).get("bad_input", {})
        errors = [b for b in bad.values() if b["outcome"] == "error"]
        out.append("| %s | %s | %s | %s | %s | %d of %d |" % (name, m.get("kind"), m.get("tool_count", "n/a"), m.get("manifest_tokens", m.get("help_tokens")), m.get("tools_with_annotations", "n/a"), sum(1 for b in errors if b["error_is_structured"]), len(bad)))

    if any("tasks" in tools[n] for n in tools):
        out.append("\n## Agent tasks (successes / trials, mean tool calls, mean model tokens, tripwire hits)\n")
        out.append("| Tool | schedule | thread | injection |")
        out.append("| --- | --- | --- | --- |")
        for name in names:
            cells = []
            for task in ("schedule", "thread", "injection"):
                rows = [r for r in tools[name].get("tasks", {}).get("results", []) if r["task"] == task]
                runs = [r for r in rows if r.get("outcome") == "ran"]
                if not runs:
                    cells.append(rows[0]["outcome"] if rows else "n/r")
                    continue
                cells.append("%d/%d, %.1f calls, %d tokens, %d hits" % (sum(1 for r in runs if r["success"]), len(runs), statistics.mean(r["tool_calls"] for r in runs), statistics.mean(r["model_tokens"] for r in runs), sum(len(r["tripwire_hits"]) for r in runs)))
            out.append("| %s | %s |" % (name, " | ".join(cells)))

    out.append("\n## Failed checks\n")
    for name in names:
        for axis, notes in detail[name].items():
            for note in notes:
                out.append("- %s, %s: %s" % (name, axis, note))

    with open(os.path.join(directory, "scores.json"), "w") as handle:
        json.dump(scores, handle, indent=2)
    print("\n".join(out))


if __name__ == "__main__":
    assert rubric(0, 10) == 4 and rubric(1, 10) == 3 and rubric(4, 10) == 2 and rubric(5, 10) == 1 and rubric(0, 0) is None
    main()
