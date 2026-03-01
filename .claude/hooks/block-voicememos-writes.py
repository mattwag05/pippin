#!/usr/bin/env python3
"""PreToolUse hook: block any write/execute targeting the Voice Memos SQLite database."""
import sys
import json
import os

tool_input = json.loads(os.environ.get("CLAUDE_TOOL_INPUT", "{}"))

paths_to_check = [
    tool_input.get("file_path", ""),
    tool_input.get("command", ""),
    tool_input.get("path", ""),
    tool_input.get("old_string", ""),  # Edit tool — catches path in diff context
]

for p in paths_to_check:
    if "com.apple.voicememos" in str(p):
        print("BLOCKED: Voice Memos database is read-only.")
        print("Use VoiceMemosDB class read methods — never write directly to the SQLite file.")
        sys.exit(1)
