"""Unit tests for pippin_memos."""

from __future__ import annotations

import argparse
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

    def test_invalid_since_raises(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        with pytest.raises(ValueError, match="Invalid --since date"):
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
    def test_missing_memo_raises(self, db_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        with pytest.raises(ValueError, match="No memo found"):
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

    def test_export_evicted_raises(self, db_path, tmp_path):
        db = pm.VoiceMemosDB(db_path=str(db_path))
        with pytest.raises(ValueError, match="evicted to iCloud"):
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


# ---------------------------------------------------------------------------
# _die()
# ---------------------------------------------------------------------------


class TestDie:
    def test_writes_json_to_stderr(self, capsys):
        with pytest.raises(SystemExit):
            pm._die("something went wrong")
        err = json.loads(capsys.readouterr().err)
        assert err == {"error": "something went wrong"}

    def test_exits_code_1(self):
        with pytest.raises(SystemExit) as exc_info:
            pm._die("test error")
        assert exc_info.value.code == 1


# ---------------------------------------------------------------------------
# cmd_list
# ---------------------------------------------------------------------------


class TestCmdList:
    def _make_args(self, db_path, since=None, fmt="json"):
        ns = argparse.Namespace()
        ns.db = str(db_path)
        ns.since = since
        ns.format = fmt
        return ns

    def test_json_output_schema(self, db_path, capsys):
        pm.cmd_list(self._make_args(db_path))
        out = json.loads(capsys.readouterr().out)
        assert isinstance(out, list)
        assert len(out) == 4
        required_keys = {"id", "title", "duration_seconds", "created_at", "file_path", "transcription"}
        assert required_keys == set(out[0].keys())

    def test_since_filtering_excludes_old(self, db_path, capsys):
        pm.cmd_list(self._make_args(db_path, since="2025-01-01"))
        out = json.loads(capsys.readouterr().out)
        ids = {m["id"] for m in out}
        assert "AAA00000-0000-0000-0000-000000000001" not in ids
        assert "DDD00000-0000-0000-0000-000000000004" not in ids

    def test_since_filtering_includes_new(self, db_path, capsys):
        pm.cmd_list(self._make_args(db_path, since="2025-01-01"))
        out = json.loads(capsys.readouterr().out)
        ids = {m["id"] for m in out}
        assert "BBB00000-0000-0000-0000-000000000002" in ids
        assert "CCC00000-0000-0000-0000-000000000003" in ids

    def test_format_text_tab_separated(self, db_path, capsys):
        pm.cmd_list(self._make_args(db_path, fmt="text"))
        out = capsys.readouterr().out
        lines = [l for l in out.strip().split("\n") if l]
        assert len(lines) == 4
        # Each line: id TAB created_at TAB duration TAB title
        parts = lines[0].split("\t")
        assert len(parts) == 4

    def test_invalid_since_exits_with_json_error(self, db_path, capsys):
        with pytest.raises(SystemExit):
            pm.cmd_list(self._make_args(db_path, since="not-a-date"))
        err = json.loads(capsys.readouterr().err)
        assert "error" in err
        assert "Invalid --since" in err["error"]


# ---------------------------------------------------------------------------
# cmd_info
# ---------------------------------------------------------------------------


class TestCmdInfo:
    def _make_args(self, db_path, memo_id):
        ns = argparse.Namespace()
        ns.db = str(db_path)
        ns.id = memo_id
        return ns

    def test_json_output(self, db_path, capsys):
        pm.cmd_info(self._make_args(db_path, "AAA00000-0000-0000-0000-000000000001"))
        out = json.loads(capsys.readouterr().out)
        assert out["id"] == "AAA00000-0000-0000-0000-000000000001"
        assert out["title"] == "Old Recording"
        required_keys = {"id", "title", "duration_seconds", "created_at", "file_path", "transcription"}
        assert required_keys == set(out.keys())

    def test_nonexistent_id_exits_with_json_error(self, db_path, capsys):
        with pytest.raises(SystemExit):
            pm.cmd_info(self._make_args(db_path, "NONEXISTENT-UUID"))
        err = json.loads(capsys.readouterr().err)
        assert "error" in err
        assert "No memo found" in err["error"]


# ---------------------------------------------------------------------------
# cmd_export --all (batch)
# ---------------------------------------------------------------------------


class TestCmdExportAll:
    def _make_args(self, db_path, output_dir, all_memos=True, memo_id=None, transcribe=False):
        ns = argparse.Namespace()
        ns.db = str(db_path)
        ns.output = str(output_dir)
        ns.all = all_memos
        ns.id = memo_id
        ns.transcribe = transcribe
        return ns

    def test_batch_exports_non_evicted(self, db_path, audio_files, tmp_path, capsys):
        pm.cmd_export(self._make_args(db_path, tmp_path))
        out = json.loads(capsys.readouterr().out)
        assert isinstance(out, list)
        assert len(out) == 4  # all 4 memos processed (1 evicted → error entry)
        exported = [r for r in out if "exported_to" in r]
        assert len(exported) == 3

    def test_batch_continues_on_individual_failure(self, db_path, audio_files, tmp_path, capsys):
        """Evicted memo produces an error entry; batch does not abort."""
        pm.cmd_export(self._make_args(db_path, tmp_path))
        out = json.loads(capsys.readouterr().out)
        error_entries = [r for r in out if "error" in r]
        assert len(error_entries) >= 1
        # Successful entries must include id and exported_to
        success_entries = [r for r in out if "exported_to" in r]
        for entry in success_entries:
            assert "id" in entry
            assert Path(entry["exported_to"]).exists()

    def test_empty_db_returns_empty_list(self, empty_db_path, tmp_path, capsys):
        pm.cmd_export(self._make_args(empty_db_path, tmp_path))
        out = json.loads(capsys.readouterr().out)
        assert out == []


# ---------------------------------------------------------------------------
# main() dispatch — error catching
# ---------------------------------------------------------------------------


class TestMainDispatch:
    def test_runtime_error_caught_as_json(self, bad_schema_db_path, capsys):
        """RuntimeError (schema version guard) is caught in main() → JSON error on stderr."""
        with patch("sys.argv", ["pippin-memos", "--db", str(bad_schema_db_path), "list"]):
            with pytest.raises(SystemExit):
                pm.main()
        err = json.loads(capsys.readouterr().err)
        assert "error" in err
        assert "Unknown Voice Memos schema version" in err["error"]

    def test_sqlite3_error_caught_as_json(self, db_path, capsys):
        """sqlite3.Error that escapes cmd_* is caught in main() → JSON error on stderr."""
        import sqlite3 as _sqlite3
        with patch("sys.argv", ["pippin-memos", "--db", str(db_path), "list"]):
            with patch.object(pm.VoiceMemosDB, "list_memos", side_effect=_sqlite3.Error("disk I/O error")):
                with pytest.raises(SystemExit):
                    pm.main()
        err = json.loads(capsys.readouterr().err)
        assert "error" in err
        assert "disk I/O error" in err["error"]
