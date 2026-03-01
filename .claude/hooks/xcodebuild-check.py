#!/usr/bin/env python3
"""PostToolUse hook: run xcodebuild after any .swift edit to catch syntax errors immediately."""
import sys
import json
import os
import subprocess

tool_input = json.loads(os.environ.get("CLAUDE_TOOL_INPUT", "{}"))
file_path = tool_input.get("file_path", "")

if not file_path.endswith(".swift"):
    sys.exit(0)

project_dir = "/Users/matthewwagner/Projects/pippin"
result = subprocess.run(
    ["xcodebuild", "-scheme", "pippin", "build", "-quiet"],
    cwd=project_dir,
    capture_output=True,
    text=True,
)

if result.returncode != 0:
    output = (result.stdout + result.stderr)[-2000:]
    print(f"Build check failed after editing {os.path.basename(file_path)}:")
    print(output)
    sys.exit(1)
else:
    print(f"Build check passed ({os.path.basename(file_path)})")
