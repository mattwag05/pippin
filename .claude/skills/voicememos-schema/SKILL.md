---
name: voicememos-schema
description: Inspect the live Voice Memos SQLite schema and map columns to VoiceMemosDB output types. Run when starting memos development or after a macOS update to verify schema compatibility.
---

## Step 1: Locate the Database

```bash
ls ~/Library/Application\ Support/com.apple.voicememos/Recordings/*.sqlite 2>/dev/null \
  || ls ~/Library/Application\ Support/com.apple.voicememos/*.sqlite 2>/dev/null
```

If no file is found, Voice Memos may not have been opened yet or Full Disk Access hasn't been granted to Terminal. Stop and report this.

## Step 2: Query the Schema

```bash
DB=$(ls ~/Library/Application\ Support/com.apple.voicememos/Recordings/*.sqlite 2>/dev/null | head -1)
echo "=== TABLES ==="
sqlite3 "$DB" ".tables"
echo ""
echo "=== FULL SCHEMA ==="
sqlite3 "$DB" ".schema"
echo ""
echo "=== ROW COUNT PER TABLE ==="
sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table';" | \
  while read t; do echo "$t: $(sqlite3 "$DB" "SELECT COUNT(*) FROM \"$t\";")"; done
```

## Step 3: Check Schema Version

```bash
sqlite3 "$DB" "SELECT * FROM Z_METADATA;" 2>/dev/null \
  || sqlite3 "$DB" "SELECT * FROM ZMETADATA;" 2>/dev/null \
  || echo "No metadata table found"
```

Note the `Z_VERSION` value — this is what the schema version guard in `VoiceMemosDB.__init__` must validate against.

## Step 4: Map Columns to Output Schema

For each table, map columns to the documented VoiceMemosDB output schema:

| SQLite Column | Table | Python Type | VoiceMemosDB Field | Notes |
|---|---|---|---|---|
| ZPKRECORDINGID or Z_PK | main recordings table | str | `id` | Use as opaque string ID |
| ZTITLE | | str | `title` | May be NULL for auto-named memos |
| ZDURATION | | float | `duration_seconds` | In seconds |
| ZCREATEDDATE | | float → datetime | `created_at` | **Core Data epoch**: add 978307200 to get Unix timestamp |
| ZPATH or ZRELATIVEPATH | | str | `file_path` | May be relative to the Recordings dir |
| _(transcription column)_ | | str or NULL | `transcription` | Column name varies by OS version |

Flag any columns present in the schema but not mapped — they may be new in this OS version and could be useful.

## Step 5: Report

Output a completed mapping table and:
- **Schema version**: the Z_VERSION value found
- **Known safe versions**: list what the `VoiceMemosDB` class currently supports
- **Action required**: COMPATIBLE / UPDATE VERSION GUARD / SCHEMA CHANGED — INVESTIGATE

If schema has changed from expected, describe which tables/columns are new, renamed, or missing, and suggest the minimal VoiceMemosDB code changes needed.
