"""Scores methodology axis 8, Operability, as Amendment 3 defines it.

    python3 harness/operability.py <results-dir>

Reads <results-dir>/facts.json (checks 1 and 3 to 13 per tool, each with evidence) and
<results-dir>/install-times.json ({tool: seconds}, check 2), and writes
<results-dir>/summary.md. A check that is missing or null counts as failed.
"""

from __future__ import annotations

import json
import os
import sys

CHECKS = [
    "install_commands", "install_time", "self_check", "permission_diagnosis", "install_documented",
    "permissions_documented", "interface_documented", "tests", "ci", "tagged_releases",
    "verifiable_artifact", "recent_commits", "recent_release",
]
INSTALL_LIMIT_SECONDS = 120


def score(failed: int) -> int:
    """Amendment 3: 4 all pass, 3 one fails, 2 two to five fail, 1 six or more fail."""
    if failed == 0:
        return 4
    if failed == 1:
        return 3
    if failed <= 5:
        return 2
    return 1


def evaluate(checks: dict, seconds) -> dict:
    results = {}
    for name in CHECKS:
        if name == "install_time":
            results[name] = seconds is not None and seconds <= INSTALL_LIMIT_SECONDS
        else:
            results[name] = (checks.get(name) or {}).get("pass") is True
    failed = [name for name, ok in results.items() if not ok]
    return {"score": score(len(failed)), "failed": failed}


def main() -> int:
    out = sys.argv[1]
    facts = json.load(open(os.path.join(out, "facts.json")))["tools"]
    times = json.load(open(os.path.join(out, "install-times.json")))
    rows = []
    for name in sorted(facts):
        result = evaluate(facts[name]["checks"], times.get(name))
        rows.append((name, result))
    lines = [
        "# Operability, 2026-11-10",
        "",
        "Scored by `harness/operability.py` under [Amendment 3](../../../../docs/competitive/methodology.md#amendment-3-2026-11-10-before-any-operability-data-was-collected). Facts with their evidence: [facts.json](facts.json). Install seconds (check 2): [install-times.json](install-times.json).",
        "",
        "| Tool | Score | Checks passed | Failed checks |",
        "| --- | --- | --- | --- |",
    ]
    for name, result in sorted(rows, key=lambda row: (-row[1]["score"], len(row[1]["failed"]), row[0])):
        passed = len(CHECKS) - len(result["failed"])
        lines.append("| %s | %d | %d of %d | %s |" % (name, result["score"], passed, len(CHECKS), ", ".join(result["failed"]) or "none"))
    with open(os.path.join(out, "summary.md"), "w") as handle:
        handle.write("\n".join(lines) + "\n")
    print("\n".join(lines[4:]))
    return 0


if __name__ == "__main__":
    assert score(0) == 4 and score(1) == 3 and score(2) == 2 and score(5) == 2 and score(6) == 1
    assert evaluate({}, None)["score"] == 1, "unknown checks count as failed"
    full = {name: {"pass": True} for name in CHECKS}
    assert evaluate(full, 10)["score"] == 4
    assert evaluate(full, 121)["failed"] == ["install_time"]
    assert evaluate(dict(full, ci={"pass": None}), 10)["failed"] == ["ci"]
    sys.exit(main())
