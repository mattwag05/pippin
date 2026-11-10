#!/usr/bin/env python3
"""Seed Voice Memos with silent recordings. Run ONLY inside the disposable benchmark VM.

  make_memos.py install <manifest.json>   prints state JSON
  make_memos.py restore                   puts CloudRecordings.db.orig back and removes the files

The store is the one Voice Memos created itself on first launch (vm/mail-setup.sh opens the app once with a
display). Rows go into its own ZCLOUDRECORDING table, so the schema is the real one for this macOS.
Standard library only, Python 3.9.
"""
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import wave

RECORDINGS = os.path.expanduser("~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
DB = os.path.join(RECORDINGS, "CloudRecordings.db")
CORE_DATA_EPOCH = 978307200  # 2001-01-01T00:00:00Z


def stop_app():
    subprocess.run(["pkill", "-x", "VoiceMemos"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-x", "voicememod"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def silent_m4a(path, seconds):
    wav = path + ".wav"
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(struct.pack("<h", 0) * int(16000 * seconds))
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", wav, path], check=True, capture_output=True)
    os.remove(wav)


def install(manifest_path):
    recordings = json.load(open(manifest_path, encoding="utf-8"))["memos"]["recordings"]
    if not os.path.exists(DB):
        print("make_memos: no CloudRecordings.db; open Voice Memos once with a display (vm/mail-setup.sh)", file=sys.stderr)
        return 1
    stop_app()
    if not os.path.exists(DB + ".orig"):
        con = sqlite3.connect(DB)
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        con.close()
        shutil.copy2(DB, DB + ".orig")
    restore(quiet=True)
    con = sqlite3.connect(DB)
    ent = con.execute("SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'CloudRecording'").fetchone()[0]
    top = con.execute("SELECT coalesce(max(Z_PK), 0) FROM ZCLOUDRECORDING").fetchone()[0]
    for i, r in enumerate(recordings):
        silent_m4a(os.path.join(RECORDINGS, r["file"]), r["duration"])
        con.execute(
            "INSERT INTO ZCLOUDRECORDING (Z_PK, Z_ENT, Z_OPT, ZFLAGS, ZDATE, ZDURATION, ZLOCALDURATION, ZCUSTOMLABEL,"
            " ZCUSTOMLABELFORSORTING, ZPATH, ZUNIQUEID) VALUES (?, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?)",
            (top + i + 1, ent, r["date_epoch"] - CORE_DATA_EPOCH, r["duration"], r["duration"], r["title"], r["title"], r["file"], r["uuid"]),
        )
    con.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_ENT = ?", (top + len(recordings), ent))
    con.commit()
    con.close()
    json.dump({"memos": {"count": len(recordings)}}, sys.stdout)
    return 0


def restore(quiet=False):
    stop_app()
    if os.path.exists(DB + ".orig"):
        for suffix in ("-wal", "-shm"):
            if os.path.exists(DB + suffix):
                os.remove(DB + suffix)
        shutil.copy2(DB + ".orig", DB)
    for name in os.listdir(RECORDINGS):
        if name.startswith("PB Memo ") and name.endswith(".m4a"):
            os.remove(os.path.join(RECORDINGS, name))
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "install":
        sys.exit(install(sys.argv[2]))
    if len(sys.argv) >= 2 and sys.argv[1] == "restore":
        sys.exit(restore())
    print(__doc__, file=sys.stderr)
    sys.exit(2)
