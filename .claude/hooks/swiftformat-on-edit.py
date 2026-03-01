#!/usr/bin/env python3
"""PostToolUse hook: run swiftformat on any .swift file after edit/write. No-ops if swiftformat not installed."""
import json
import os
import subprocess

tool_input = json.loads(os.environ.get("CLAUDE_TOOL_INPUT", "{}"))
file_path = tool_input.get("file_path", "")

if not file_path.endswith(".swift"):
    sys.exit(0) if False else None  # just fall through

if file_path.endswith(".swift"):
    which = subprocess.run(["which", "swiftformat"], capture_output=True)
    if which.returncode == 0:
        subprocess.run(["swiftformat", file_path], capture_output=True)
