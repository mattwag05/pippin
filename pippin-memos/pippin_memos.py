"""pippin-memos — Voice Memos CLI for the pippin macOS toolkit.

Reads the Voice Memos SQLite database directly. No recording, no sync.
Output: JSON to stdout, errors to stderr.

Schema notes (verified on macOS 26 Tahoe, 2026-03-01):
  Database: ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/
              Recordings/CloudRecordings.db
  Table:    ZCLOUDRECORDING
  Columns used: ZUNIQUEID (UUID string), ZDATE (Core Data epoch),
                ZDURATION (float seconds), ZPATH (filename relative to
                Recordings dir), ZCUSTOMLABELFORSORTING (display title),
                ZEVICTIONDATE (non-null means iCloud-evicted/missing locally)
  Z_VERSION: 1
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# Core Data epoch offset: seconds between 2001-01-01 UTC and Unix epoch
CORE_DATA_EPOCH = 978307200

# Known-safe schema versions (Z_METADATA.Z_VERSION)
# macOS 26 Tahoe: 1
KNOWN_SCHEMA_VERSIONS = {1}

# Canonical database path (macOS 14+, Group Container)
_DB_PATH = (
    "~/Library/Group Containers/group.com.apple.VoiceMemos.shared"
    "/Recordings/CloudRecordings.db"
)


@dataclass
class VoiceMemo:
    id: str               # ZUNIQUEID (UUID string)
    title: str            # ZCUSTOMLABELFORSORTING
    duration_seconds: float
    created_at: str       # ISO 8601, UTC
    file_path: str        # absolute path to recording file (.m4a or .qta)
    transcription: Optional[str]


def _die(message: str) -> None:
    """Write JSON error to stderr and exit 1."""
    json.dump({"error": message}, sys.stderr, ensure_ascii=False)
    sys.stderr.write("\n")
    sys.exit(1)


def _core_data_to_iso(timestamp: float) -> str:
    """Convert Core Data timestamp to ISO 8601 UTC string."""
    unix = timestamp + CORE_DATA_EPOCH
    dt = datetime.fromtimestamp(unix, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


class VoiceMemosDB:
    """Read-only accessor for the Voice Memos SQLite database."""

    def __init__(self, db_path: Optional[str] = None) -> None:
        if db_path:
            self._db_path = Path(db_path).expanduser().resolve()
        else:
            self._db_path = Path(_DB_PATH).expanduser()

        if not self._db_path.exists():
            _die(
                f"Voice Memos database not found at {self._db_path}. "
                "Open Voice Memos, create at least one recording, and grant "
                "Terminal Full Disk Access in System Settings → Privacy & Security."
            )

        self._recordings_dir = self._db_path.parent
        self._validate_schema()

    def _connect(self) -> sqlite3.Connection:
        """Open a read-only connection via URI."""
        uri = self._db_path.as_uri() + "?mode=ro"
        return sqlite3.connect(uri, uri=True)

    def _validate_schema(self) -> None:
        """Raise RuntimeError if the schema version is unknown."""
        try:
            con = self._connect()
            try:
                row = con.execute(
                    "SELECT Z_VERSION FROM Z_METADATA LIMIT 1"
                ).fetchone()
            finally:
                con.close()
        except sqlite3.OperationalError as exc:
            raise RuntimeError(
                f"Could not read Z_METADATA from {self._db_path}: {exc}. "
                "The database schema may have changed."
            ) from exc

        if row is None:
            raise RuntimeError("Z_METADATA is empty — cannot determine schema version.")

        version = row[0]
        if version not in KNOWN_SCHEMA_VERSIONS:
            raise RuntimeError(
                f"Unknown Voice Memos schema version {version!r}. "
                f"Known versions: {sorted(KNOWN_SCHEMA_VERSIONS)}. "
                "macOS may have updated the database format. "
                "Run `/voicememos-schema` and update KNOWN_SCHEMA_VERSIONS."
            )

    def _row_to_memo(self, row: sqlite3.Row) -> VoiceMemo:
        uid = str(row["ZUNIQUEID"] or row["Z_PK"])
        title = row["ZCUSTOMLABELFORSORTING"] or f"Recording {uid[:8]}"
        duration = float(row["ZDURATION"] or 0.0)
        created_at = _core_data_to_iso(float(row["ZDATE"] or 0.0))
        raw_path = row["ZPATH"] or ""
        if raw_path:
            p = Path(raw_path)
            file_path = str(p if p.is_absolute() else self._recordings_dir / p)
        else:
            file_path = ""
        return VoiceMemo(
            id=uid,
            title=title,
            duration_seconds=round(duration, 3),
            created_at=created_at,
            file_path=file_path,
            transcription=None,
        )

    def list_memos(self, since: Optional[str] = None) -> list[VoiceMemo]:
        """Return all recordings, optionally filtered by creation date."""
        since_ts: Optional[float] = None
        if since:
            try:
                dt = datetime.fromisoformat(since).replace(tzinfo=timezone.utc)
                since_ts = dt.timestamp() - CORE_DATA_EPOCH
            except ValueError:
                _die(f"Invalid --since date {since!r}. Use YYYY-MM-DD.")

        query = (
            "SELECT Z_PK, ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH "
            "FROM ZCLOUDRECORDING"
        )
        params: list = []
        if since_ts is not None:
            query += " WHERE ZDATE >= ?"
            params.append(since_ts)
        query += " ORDER BY ZDATE DESC"

        con = self._connect()
        try:
            con.row_factory = sqlite3.Row
            return [self._row_to_memo(r) for r in con.execute(query, params).fetchall()]
        finally:
            con.close()

    def get_memo(self, memo_id: str) -> VoiceMemo:
        """Return a single recording by its ZUNIQUEID."""
        con = self._connect()
        try:
            con.row_factory = sqlite3.Row
            row = con.execute(
                "SELECT Z_PK, ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH "
                "FROM ZCLOUDRECORDING WHERE ZUNIQUEID = ?",
                (memo_id,),
            ).fetchone()
        finally:
            con.close()

        if row is None:
            _die(f"No memo found with id {memo_id!r}.")

        return self._row_to_memo(row)  # type: ignore[arg-type]

    def is_evicted(self, memo_id: str) -> bool:
        """Return True if the recording has been evicted to iCloud."""
        con = self._connect()
        try:
            row = con.execute(
                "SELECT ZEVICTIONDATE FROM ZCLOUDRECORDING WHERE ZUNIQUEID = ?",
                (memo_id,),
            ).fetchone()
        finally:
            con.close()
        return row is not None and row[0] is not None

    def export_memo(self, memo_id: str, output_dir: str) -> str:
        """Copy recording to output_dir as YYYY-MM-DD_title.<ext>. Returns dest path."""
        memo = self.get_memo(memo_id)

        if not memo.file_path:
            _die(f"Memo {memo_id!r} has no file path recorded in the database.")

        src = Path(memo.file_path)
        if not src.exists():
            if self.is_evicted(memo_id):
                _die(
                    f"Recording '{memo.title}' has been evicted to iCloud. "
                    "Open Voice Memos and download it before exporting."
                )
            _die(f"Recording file not found: {src}")

        out = Path(output_dir).expanduser().resolve()
        out.mkdir(parents=True, exist_ok=True)

        # Preserve original extension (.m4a or .qta)
        ext = src.suffix
        date_prefix = memo.created_at[:10]  # YYYY-MM-DD
        safe_title = "".join(c if c.isalnum() or c in " -_." else "_" for c in memo.title)
        safe_title = safe_title.strip().replace(" ", "-")
        dest_name = f"{date_prefix}_{safe_title}{ext}"
        dest = out / dest_name

        # Avoid silent overwrite — append numeric suffix if needed
        if dest.exists():
            stem = dest.stem
            i = 1
            while dest.exists():
                dest = out / f"{stem}_{i}{ext}"
                i += 1

        shutil.copy2(str(src), str(dest))
        return str(dest)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _memo_to_dict(memo: VoiceMemo) -> dict:
    return asdict(memo)


def cmd_list(args: argparse.Namespace) -> None:
    db = VoiceMemosDB(db_path=getattr(args, "db", None))
    memos = db.list_memos(since=getattr(args, "since", None))
    dicts = [_memo_to_dict(m) for m in memos]
    if getattr(args, "format", "json") == "text":
        for m in memos:
            print(f"{m.id}\t{m.created_at}\t{m.duration_seconds:.1f}s\t{m.title}")
    else:
        print(json.dumps(dicts, ensure_ascii=False, indent=2))


def cmd_info(args: argparse.Namespace) -> None:
    db = VoiceMemosDB(db_path=getattr(args, "db", None))
    memo = db.get_memo(args.id)
    print(json.dumps(_memo_to_dict(memo), ensure_ascii=False, indent=2))


def cmd_export(args: argparse.Namespace) -> None:
    db = VoiceMemosDB(db_path=getattr(args, "db", None))
    output_dir = args.output
    transcribe = getattr(args, "transcribe", False)

    if getattr(args, "all", False):
        memos = db.list_memos()
        if not memos:
            print(json.dumps([], ensure_ascii=False, indent=2))
            return
        results = []
        for memo in memos:
            try:
                result = _export_and_maybe_transcribe(db, memo.id, output_dir, transcribe)
                results.append(result)
            except SystemExit:
                results.append({"id": memo.id, "title": memo.title, "error": "export failed"})
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        result = _export_and_maybe_transcribe(db, args.id, output_dir, transcribe)
        print(json.dumps(result, ensure_ascii=False, indent=2))


def _transcribe_file(audio_path: str) -> str:
    """Run parakeet-mlx on audio_path and return plain-text transcription."""
    binary = shutil.which("parakeet-mlx")
    if not binary:
        _die(
            "parakeet-mlx not found. Install it with: pipx install parakeet-mlx"
        )

    with tempfile.TemporaryDirectory() as tmp_dir:
        result = subprocess.run(
            [binary, audio_path, "--output-format", "txt", "--output-dir", tmp_dir],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if result.returncode != 0:
            _die(f"parakeet-mlx failed: {result.stderr.strip()}")

        txt_files = list(Path(tmp_dir).glob("*.txt"))
        if not txt_files:
            _die("parakeet-mlx produced no .txt output")

        return txt_files[0].read_text(encoding="utf-8")


def _export_and_maybe_transcribe(
    db: "VoiceMemosDB", memo_id: str, output_dir: str, transcribe: bool
) -> dict:
    """Export a single memo and optionally transcribe it. Returns result dict."""
    dest = db.export_memo(memo_id, output_dir)
    memo = db.get_memo(memo_id)
    result: dict = {"id": memo.id, "title": memo.title, "exported_to": dest}

    if transcribe:
        txt_path = str(Path(dest).with_suffix(".txt"))
        ext = Path(dest).suffix.lower()
        if ext not in (".m4a", ".qta"):
            result["transcription_warning"] = f"Unknown audio format {ext!r}; skipped."
        else:
            try:
                text = _transcribe_file(dest)
                Path(txt_path).write_text(text, encoding="utf-8")
                result["transcription_file"] = txt_path
                result["transcription"] = text
            except SystemExit:
                result["transcription_warning"] = "Transcription failed (see stderr)."

    return result


def cmd_delete(args: argparse.Namespace) -> None:
    db = VoiceMemosDB(db_path=getattr(args, "db", None))
    memo = db.get_memo(args.id)  # exits if not found

    if not memo.file_path:
        _die(f"Memo {args.id!r} has no file path recorded in the database.")

    if db.is_evicted(args.id):
        _die(
            f"Recording '{memo.title}' has been evicted to iCloud and is not "
            "stored locally. Cannot delete."
        )

    src = Path(memo.file_path)
    if not src.exists():
        _die(f"Recording file not found locally: {src}")

    if not shutil.which("trash"):
        _die(
            "The `trash` CLI is required for safe deletion. "
            "Install it with: brew install trash"
        )

    if getattr(args, "dry_run", False):
        print(
            json.dumps(
                {
                    "id": memo.id,
                    "title": memo.title,
                    "file_path": memo.file_path,
                    "deleted": False,
                    "dry_run": True,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return

    result = subprocess.run(["trash", memo.file_path], capture_output=True, text=True)
    if result.returncode != 0:
        _die(f"trash failed (exit {result.returncode}): {result.stderr.strip()}")

    print(
        json.dumps(
            {
                "id": memo.id,
                "title": memo.title,
                "file_path": memo.file_path,
                "deleted": True,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pippin-memos",
        description="Voice Memos CLI — read-only access via SQLite.",
    )
    parser.add_argument(
        "--db",
        metavar="PATH",
        help="Override Voice Memos database path (for testing).",
        default=None,
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # list
    p_list = sub.add_parser("list", help="List all recordings as JSON.")
    p_list.add_argument(
        "--since",
        metavar="YYYY-MM-DD",
        help="Only return recordings created on or after this date.",
        default=None,
    )
    p_list.add_argument(
        "--format",
        choices=["json", "text"],
        default="json",
        help="Output format (default: json).",
    )

    # info
    p_info = sub.add_parser("info", help="Show full metadata for a single recording.")
    p_info.add_argument("id", help="Memo id (UUID) from `pippin-memos list` output.")

    # export
    p_export = sub.add_parser("export", help="Copy recording(s) to a directory.")
    p_export.add_argument(
        "--output",
        required=True,
        metavar="DIR",
        help="Destination directory (created if absent).",
    )
    id_group = p_export.add_mutually_exclusive_group(required=True)
    id_group.add_argument("id", nargs="?", help="Memo UUID to export.")
    id_group.add_argument("--all", action="store_true", help="Export every recording.")
    p_export.add_argument(
        "--transcribe",
        action="store_true",
        default=False,
        help="Transcribe audio with parakeet-mlx and write a .txt sidecar alongside the export.",
    )

    # delete
    p_delete = sub.add_parser(
        "delete",
        help="Move recording file to Trash. DB row lingers until Voice Memos.app cleans up.",
    )
    p_delete.add_argument("id", help="Memo UUID from `pippin-memos list` output.")
    p_delete.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Print what would happen without moving to Trash.",
    )

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    try:
        if args.command == "list":
            cmd_list(args)
        elif args.command == "info":
            cmd_info(args)
        elif args.command == "export":
            cmd_export(args)
        elif args.command == "delete":
            cmd_delete(args)
    except RuntimeError as exc:
        _die(str(exc))
    except KeyboardInterrupt:
        sys.exit(1)


if __name__ == "__main__":
    main()
