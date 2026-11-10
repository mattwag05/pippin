"""Parsing and argument helpers shared by the adapters. No benchmark logic,
no per-tool knowledge. Standard library only, Python 3.9."""

from __future__ import annotations

import json


def first_json(text: str, marker: str | None = None):
    """First JSON object or array embedded in text. With a marker, the value
    must directly follow one occurrence of the marker and run to the end of
    the text (for servers that append a JSON mirror after prose)."""
    dec = json.JSONDecoder()
    if marker is not None:
        at = text.find(marker)
        while at != -1:
            try:
                value, end = dec.raw_decode(text, at + len(marker))
                if not text[end:].strip():
                    return value
            except ValueError:
                pass
            at = text.find(marker, at + 1)
        return None
    for i, ch in enumerate(text):
        if ch in "{[":
            try:
                return dec.raw_decode(text, i)[0]
            except ValueError:
                continue
    return None


def ndjson(text: str) -> list:
    return [json.loads(line) for line in text.splitlines() if line.strip().startswith("{")]


def pick(d: dict, *keys):
    """First key that is present and not None."""
    for k in keys:
        if d.get(k) is not None:
            return d[k]
    return None


def rec(**kw) -> dict:
    """A normalized record without the keys the tool did not provide."""
    return {k: v for k, v in kw.items() if v is not None}


def rows(value, *keys) -> list:
    """The record list inside a parsed reply: the value itself when it is a
    list, else the first listed key that holds a list, else the dict as one row."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for k in keys:
            if isinstance(value.get(k), list):
                return value[k]
            if isinstance(value.get(k), dict):
                return [value[k]]
        return [value]
    return []


def named(args: dict, mapping: dict) -> dict:
    """{tool_key: args[canonical_key]} for the canonical keys that were given."""
    return {tool: args[canon] for tool, canon in mapping.items() if args.get(canon) is not None}


def flags(args: dict, mapping: dict) -> list:
    """["--flag", str(value), ...] for the canonical keys that were given."""
    out = []
    for flag, canon in mapping.items():
        if args.get(canon) is not None:
            out += [flag, str(args[canon])]
    return out


def values(items) -> list:
    """Plain strings from a list of strings or {label, value} objects."""
    return [i.get("value") if isinstance(i, dict) else i for i in (items or [])]
