"""Shared fixtures for pippin-memos tests."""

from __future__ import annotations

import sqlite3
import tempfile
from pathlib import Path

import pytest

# Core Data epoch constant (seconds between 2001-01-01 UTC and Unix epoch)
CORE_DATA_EPOCH = 978307200


def _unix_to_core(unix_ts: float) -> float:
    return unix_ts - CORE_DATA_EPOCH


# Representative Core Data timestamps (pre-computed for known dates)
# 2024-06-15T12:00:00Z  → unix 1718445600
# 2025-03-01T08:30:00Z  → unix 1740818600 (approx 1740818400 + 200)
# 2026-01-10T00:00:00Z  → unix 1768003200 (approx)

MEMO_ROWS = [
    {
        "Z_PK": 1,
        "ZUNIQUEID": "AAA00000-0000-0000-0000-000000000001",
        "ZCUSTOMLABELFORSORTING": "Old Recording",
        "ZDURATION": 61.5,
        "ZDATE": _unix_to_core(1718445600.0),   # 2024-06-15
        "ZPATH": "recording1.m4a",
        "ZEVICTIONDATE": None,
    },
    {
        "Z_PK": 2,
        "ZUNIQUEID": "BBB00000-0000-0000-0000-000000000002",
        "ZCUSTOMLABELFORSORTING": "Mid Recording",
        "ZDURATION": 120.0,
        "ZDATE": _unix_to_core(1740818400.0),   # 2025-03-01 (approx)
        "ZPATH": "recording2.qta",
        "ZEVICTIONDATE": None,
    },
    {
        "Z_PK": 3,
        "ZUNIQUEID": "CCC00000-0000-0000-0000-000000000003",
        "ZCUSTOMLABELFORSORTING": "New Recording",
        "ZDURATION": 30.0,
        "ZDATE": _unix_to_core(1768003200.0),   # 2026-01-10 (approx)
        "ZPATH": "recording3.m4a",
        "ZEVICTIONDATE": None,
    },
    {
        "Z_PK": 4,
        "ZUNIQUEID": "DDD00000-0000-0000-0000-000000000004",
        "ZCUSTOMLABELFORSORTING": "Evicted Recording",
        "ZDURATION": 45.0,
        "ZDATE": _unix_to_core(1718445600.0),   # 2024-06-15
        "ZPATH": "evicted.m4a",
        "ZEVICTIONDATE": _unix_to_core(1718532000.0),  # non-null = evicted
    },
]


def _create_db(path: Path, schema_version: int = 1) -> None:
    con = sqlite3.connect(str(path))
    try:
        # Metadata table
        con.execute("CREATE TABLE Z_METADATA (Z_VERSION INTEGER)")
        con.execute("INSERT INTO Z_METADATA (Z_VERSION) VALUES (?)", (schema_version,))

        # Recordings table (minimal columns pippin-memos uses)
        con.execute("""
            CREATE TABLE ZCLOUDRECORDING (
                Z_PK           INTEGER PRIMARY KEY,
                ZUNIQUEID      VARCHAR,
                ZCUSTOMLABELFORSORTING VARCHAR,
                ZDURATION      FLOAT,
                ZDATE          FLOAT,
                ZPATH          VARCHAR,
                ZEVICTIONDATE  FLOAT
            )
        """)

        for row in MEMO_ROWS:
            con.execute(
                "INSERT INTO ZCLOUDRECORDING VALUES (?,?,?,?,?,?,?)",
                (
                    row["Z_PK"],
                    row["ZUNIQUEID"],
                    row["ZCUSTOMLABELFORSORTING"],
                    row["ZDURATION"],
                    row["ZDATE"],
                    row["ZPATH"],
                    row["ZEVICTIONDATE"],
                ),
            )
        con.commit()
    finally:
        con.close()


@pytest.fixture
def db_path(tmp_path: Path) -> Path:
    """Temp SQLite DB seeded with sample recordings."""
    p = tmp_path / "CloudRecordings.db"
    _create_db(p)
    return p


@pytest.fixture
def bad_schema_db_path(tmp_path: Path) -> Path:
    """Temp SQLite DB with unknown schema version (99)."""
    p = tmp_path / "CloudRecordings_bad.db"
    _create_db(p, schema_version=99)
    return p


@pytest.fixture
def audio_files(db_path: Path) -> dict[str, Path]:
    """Create dummy audio files alongside the DB so export can copy them."""
    recordings_dir = db_path.parent
    files: dict[str, Path] = {}
    for row in MEMO_ROWS:
        if row["ZEVICTIONDATE"] is not None:
            continue  # evicted — don't create file
        p = recordings_dir / row["ZPATH"]
        p.write_bytes(b"FAKE_AUDIO")
        files[row["ZUNIQUEID"]] = p
    return files
