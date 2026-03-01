"""Unit tests for pippin_memos."""

from __future__ import annotations

import json
import subprocess
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest

# Allow importing pippin_memos from the parent directory
sys.path.insert(0, str(Path(__file__).parent.parent))
import pippin_memos as pm


# ---------------------------------------------------------------------------
# Core Data epoch conversion
# ---------------------------------------------------------------------------


class TestCoreDataConversion:
    def test_known_date(self):
        # 2024-06-15T10:00:00Z → Unix 1718445600
        # Core Data: 1718445600 - 978307200 = 740138400
        result = pm._core_data_to_iso(740138400.0)
        assert result == "2024-06-15T10:00:00Z"

    def test_zero_gives_epoch_start(self):
        # Core Data 0 → 2001-01-01T00:00:00Z
        result = pm._core_data_to_iso(0.0)
        assert result == "2001-01-01T00:00:00Z"

    def test_negative_value(self):
        # Negative Core Data timestamp → before 2001
        # Core Data -1 → 2000-12-31T23:59:59Z
        result = pm._core_data_to_iso(-1.0)
        assert result == "2000-12-31T23:59:59Z"

    def test_fractional_seconds_truncated(self):
        # strftime with %S truncates sub-second
        result = pm._core_data_to_iso(740138400.9)
        assert result == "2024-06-15T10:00:00Z"


# ---------------------------------------------------------------------------
# Filename sanitization (export_memo)
# ---------------------------------------------------------------------------


class TestFilenameSanitization:
    def test_special_chars_replaced(self, db_path, audio_files, tmp_path):
        # Inject a memo with special characters in title
        import sqlite3

        con = sqlite3.connect(str(db_path))
        try:
            core_ts = 740138400.0
            recordings_dir = db_path.parent
            audio = recordings_dir / "special.m4a"
            audio.write_bytes(b"AUDIO")
            con.execute(
                "INSERT INTO ZCLOUDRECORDING VALUES (?,?,?,?,?,?,?)",
                (99, "SPEC-0000-SPEC", "Hello: World/Test?", 10.0, core_ts, "special.m4a", None),
            )
            con.commit()
        finally:
            con.close()

        db = pm.VoiceMemosDB(db_path=str(db_path))
        dest = db.export_memo("SPEC-0000-SPEC", str(tmp_path))
        assert "/" not in Path(dest).name
        assert ":" not in Path(dest).name

    def test_collision_suffix_appended(self, db_path, audio_files, tmp_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memo_id = "AAA00000-0000-0000-0000-000000000001"
        dest1 = db.export_memo(memo_id, str(tmp_path))
        dest2 = db.export_memo(memo_id, str(tmp_path))
        assert dest1 != dest2
        assert Path(dest1).exists()
        assert Path(dest2).exists()


# ---------------------------------------------------------------------------
# --since date filtering
# ---------------------------------------------------------------------------


class TestSinceFiltering:
    def test_since_2025_excludes_2024(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memos = db.list_memos(since="2025-01-01")
        ids = [m.id for m in memos]
        assert "AAA00000-0000-0000-0000-000000000001" not in ids
        assert "DDD00000-0000-0000-0000-000000000004" not in ids

    def test_since_2025_includes_2025_and_2026(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memos = db.list_memos(since="2025-01-01")
        ids = [m.id for m in memos]
        assert "BBB00000-0000-0000-0000-000000000002" in ids
        assert "CCC00000-0000-0000-0000-000000000003" in ids

    def test_since_future_returns_empty(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memos = db.list_memos(since="2099-01-01")
        assert memos == []

    def test_no_since_returns_all(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memos = db.list_memos()
        assert len(memos) == 4

    def test_invalid_since_exits(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        with pytest.raises(SystemExit):
            db.list_memos(since="not-a-date")


# ---------------------------------------------------------------------------
# Schema version guard
# ---------------------------------------------------------------------------


class TestSchemaVersionGuard:
    def test_unknown_version_raises(self, bad_schema_db_path):
        with pytest.raises(RuntimeError, match="Unknown Voice Memos schema version"):
            pm.VoiceMemosDB(db_path=str(bad_schema_db_path))

    def test_known_version_ok(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        assert db is not None


# ---------------------------------------------------------------------------
# get_memo — missing memo
# ---------------------------------------------------------------------------


class TestGetMemo:
    def test_missing_memo_exits(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        with pytest.raises(SystemExit):
            db.get_memo("NONEXISTENT-UUID")

    def test_existing_memo_ok(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memo = db.get_memo("AAA00000-0000-0000-0000-000000000001")
        assert memo.title == "Old Recording"
        assert memo.duration_seconds == 61.5


# ---------------------------------------------------------------------------
# Evicted memo
# ---------------------------------------------------------------------------


class TestEvictedMemo:
    def test_evicted_detected(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        assert db.is_evicted("DDD00000-0000-0000-0000-000000000004") is True

    def test_non_evicted(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        assert db.is_evicted("AAA00000-0000-0000-0000-000000000001") is False

    def test_export_evicted_exits(self, db_path, tmp_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        with pytest.raises(SystemExit):
            db.export_memo("DDD00000-0000-0000-0000-000000000004", str(tmp_path))


# ---------------------------------------------------------------------------
# JSON output format
# ---------------------------------------------------------------------------


class TestJsonOutputFormat:
    def test_voicememo_fields(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memo = db.get_memo("AAA00000-0000-0000-0000-000000000001")
        d = pm._memo_to_dict(memo)
        required_keys = {"id", "title", "duration_seconds", "created_at", "file_path", "transcription"}
        assert required_keys == set(d.keys())

    def test_id_is_uuid_string(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memo = db.get_memo("AAA00000-0000-0000-0000-000000000001")
        assert memo.id == "AAA00000-0000-0000-0000-000000000001"

    def test_transcription_is_none_by_default(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        memo = db.get_memo("AAA00000-0000-0000-0000-000000000001")
        assert memo.transcription is None
        d = pm._memo_to_dict(memo)
        # None serializes to JSON null
        assert json.dumps(d["transcription"]) == "null"


# ---------------------------------------------------------------------------
# cmd_delete
# ---------------------------------------------------------------------------


class TestCmdDelete:
    def _make_args(self, memo_id: str, db_path: str, dry_run: bool = False):
        import argparse
        ns = argparse.Namespace()
        ns.id = memo_id
        ns.db = db_path
        ns.dry_run = dry_run
        return ns

    def test_happy_path(self, db_path, audio_files, capsys):
        """delete moves the file to Trash (mocked) and prints JSON with deleted: true."""
        memo_id = "AAA00000-0000-0000-0000-000000000001"
        args = self._make_args(memo_id, str(db_path))
        with patch("pippin_memos.shutil.which", return_value="/usr/local/bin/trash"):
            with patch("pippin_memos.subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(returncode=0)
                pm.cmd_delete(args)
        out = json.loads(capsys.readouterr().out)
        assert out["id"] == memo_id
        assert out["deleted"] is True

    def test_dry_run(self, db_path, audio_files, capsys):
        """--dry-run prints JSON without calling trash."""
        memo_id = "AAA00000-0000-0000-0000-000000000001"
        args = self._make_args(memo_id, str(db_path), dry_run=True)
        with patch("pippin_memos.shutil.which", return_value="/usr/local/bin/trash"):
            with patch("pippin_memos.subprocess.run") as mock_run:
                pm.cmd_delete(args)
                mock_run.assert_not_called()
        out = json.loads(capsys.readouterr().out)
        assert out["deleted"] is False
        assert out["dry_run"] is True

    def test_nonexistent_memo(self, db_path):
        """Nonexistent memo ID exits with error."""
        args = self._make_args("NONEXISTENT", str(db_path))
        with pytest.raises(SystemExit):
            pm.cmd_delete(args)

    def test_evicted_memo(self, db_path, audio_files):
        """Evicted memo exits with error."""
        args = self._make_args("DDD00000-0000-0000-0000-000000000004", str(db_path))
        with pytest.raises(SystemExit):
            pm.cmd_delete(args)

    def test_missing_trash_cli(self, db_path, audio_files):
        """Missing trash CLI exits with error."""
        memo_id = "AAA00000-0000-0000-0000-000000000001"
        args = self._make_args(memo_id, str(db_path))
        with patch("pippin_memos.shutil.which", return_value=None):
            with pytest.raises(SystemExit):
                pm.cmd_delete(args)

    def test_trash_failure(self, db_path, audio_files):
        """Nonzero exit from trash CLI exits with error."""
        memo_id = "AAA00000-0000-0000-0000-000000000001"
        args = self._make_args(memo_id, str(db_path))
        with patch("pippin_memos.shutil.which", return_value="/usr/local/bin/trash"):
            with patch("pippin_memos.subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(returncode=1, stderr="permission denied")
                with pytest.raises(SystemExit):
                    pm.cmd_delete(args)


# ---------------------------------------------------------------------------
# _transcribe_file
# ---------------------------------------------------------------------------


class TestTranscribeFile:
    def test_missing_binary_exits(self):
        with patch("pippin_memos.shutil.which", return_value=None):
            with pytest.raises(SystemExit):
                pm._transcribe_file("/fake/audio.m4a")

    def test_parakeet_failure_exits(self, tmp_path):
        fake_audio = tmp_path / "test.m4a"
        fake_audio.write_bytes(b"FAKE")
        with patch("pippin_memos.shutil.which", return_value="/usr/local/bin/parakeet-mlx"):
            with patch("pippin_memos.subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(
                    returncode=1, stderr="model error", stdout=""
                )
                with pytest.raises(SystemExit):
                    pm._transcribe_file(str(fake_audio))

    def test_happy_path_returns_text(self, tmp_path):
        """Mock parakeet-mlx writing a .txt file and verify we read it back."""
        fake_audio = tmp_path / "test.m4a"
        fake_audio.write_bytes(b"FAKE")

        def fake_run(cmd, capture_output, text, timeout):
            # Find output dir arg
            idx = cmd.index("--output-dir")
            out_dir = Path(cmd[idx + 1])
            (out_dir / "test.txt").write_text("Hello world transcription.")
            return MagicMock(returncode=0)

        with patch("pippin_memos.shutil.which", return_value="/usr/local/bin/parakeet-mlx"):
            with patch("pippin_memos.subprocess.run", side_effect=fake_run):
                result = pm._transcribe_file(str(fake_audio))

        assert result == "Hello world transcription."

    def test_sidecar_written_on_export(self, db_path, audio_files, tmp_path):
        """export with --transcribe writes .txt sidecar alongside exported audio."""
        import argparse
        ns = argparse.Namespace()
        ns.id = "AAA00000-0000-0000-0000-000000000001"
        ns.db = str(db_path)
        ns.output = str(tmp_path)
        ns.all = False
        ns.transcribe = True

        def fake_run(cmd, capture_output, text, timeout):
            idx = cmd.index("--output-dir")
            out_dir = Path(cmd[idx + 1])
            # Find stem of audio file
            audio = Path(cmd[1])
            (out_dir / (audio.stem + ".txt")).write_text("Test transcription.")
            return MagicMock(returncode=0)

        with patch("pippin_memos.shutil.which", return_value="/usr/local/bin/parakeet-mlx"):
            with patch("pippin_memos.subprocess.run", side_effect=fake_run):
                import io
                from contextlib import redirect_stdout
                buf = io.StringIO()
                with redirect_stdout(buf):
                    pm.cmd_export(ns)

        out = json.loads(buf.getvalue())
        assert "transcription_file" in out
        assert out["transcription"] == "Test transcription."
        assert Path(out["transcription_file"]).exists()
