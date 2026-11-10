#!/usr/bin/env python3
"""Seed the PippinBench mailbox on the VM's local IMAP server. Run ONLY inside the disposable benchmark VM.

  make_mail.py install <manifest.json>   prints state JSON
  make_mail.py restore                   empties the mailbox

The server (Dovecot, 127.0.0.1:1143, no TLS, any password) and the Mail account `PippinBench` are set up once by
vm/mail-setup.sh. Messages are written straight into the server's Maildir; nothing is sent anywhere.
Standard library only, Python 3.9.
"""
import json
import os
import subprocess
import sys
import time
from email.message import EmailMessage
from email.utils import format_datetime
from datetime import datetime, timezone

MAILDIR = os.path.expanduser("~/bench-mail/maildir")
DOVECOT = "/opt/homebrew/opt/dovecot/sbin/dovecot"
CONF = os.path.expanduser("~/bench-mail/dovecot.conf")


def osascript(script, timeout=60):
    done = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return done.stdout.strip()


def server_up():
    if subprocess.run(["pgrep", "-f", "[s]bin/dovecot -c"], capture_output=True).returncode != 0:
        subprocess.run(["sudo", "-n", DOVECOT, "-c", CONF], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        time.sleep(5)


def clear():
    for sub in ("cur", "new", "tmp"):
        path = os.path.join(MAILDIR, sub)
        os.makedirs(path, exist_ok=True)
        for name in os.listdir(path):
            os.remove(os.path.join(path, name))
    # Dovecot's UID list and indexes too, so a reseed gets a new UIDVALIDITY and Mail re-reads every message.
    for name in os.listdir(MAILDIR):
        if name.startswith("dovecot"):
            os.remove(os.path.join(MAILDIR, name))


def mail_count():
    script = 'tell application "Mail" to count messages of mailbox "INBOX" of account "PippinBench"'
    try:
        return int(osascript(script) or "-1")
    except (ValueError, subprocess.TimeoutExpired):
        return -1


def sync(expected):
    for _ in range(60):
        osascript('tell application "Mail" to check for new mail for account "PippinBench"')
        if mail_count() == expected:
            return True
        time.sleep(2)
    return False


REBUILD = """
tell application "Mail"
  activate
  set selected mailboxes of message viewer 1 to {mailbox "INBOX" of account "PippinBench"}
end tell
delay 2
tell application "System Events" to tell process "Mail" to click menu item "Rebuild" of menu "Mailbox" of menu bar 1
"""


def received_matches(manifest):
    """Mail's received date for the newest message equals its Date header (Mail caches received dates)."""
    newest = max(manifest["messages"], key=lambda m: m["date_epoch"])
    script = ('tell application "Mail" to return (date received of (first message of mailbox "INBOX" of account "PippinBench"'
              ' whose subject is "%s")) as «class isot» as string' % newest["subject"])
    want = datetime.fromtimestamp(newest["date_epoch"]).strftime("%Y-%m-%dT%H:%M:%S")  # local time, as Mail reports it
    try:
        return osascript(script) == want
    except subprocess.TimeoutExpired:
        return False


def install(manifest_path):
    manifest = json.load(open(manifest_path, encoding="utf-8"))["mail"]
    server_up()
    clear()
    for i, m in enumerate(manifest["messages"]):
        msg = EmailMessage()
        msg["Subject"] = m["subject"]
        msg["From"] = "%s <%s>" % (m["from_name"], m["from"])
        msg["To"] = m["to"]
        msg["Date"] = format_datetime(datetime.fromtimestamp(m["date_epoch"], timezone.utc))
        msg["Message-ID"] = m["message_id"]
        msg.set_content(m["body"])
        # Maildir name: <time>.<unique>.<host>, with ":2,S" for read; the first eight are left unread.
        flags = "" if i < 8 else "S"
        name = "%d.pb%02d.pippinbench:2,%s" % (m["date_epoch"], i + 1, flags)
        path = os.path.join(MAILDIR, "cur", name)
        with open(path, "wb") as handle:
            handle.write(bytes(msg))
        # Dovecot reports a Maildir file's mtime as the received date (INTERNALDATE). Matching it to the Date
        # header gives one order whether a tool sorts by date sent or date received.
        os.utime(path, (m["date_epoch"], m["date_epoch"]))
    synced = sync(len(manifest["messages"]))
    if synced and not received_matches(manifest):
        # Mail keeps received dates it cached on an earlier seed; Mailbox > Rebuild re-reads them from the server.
        subprocess.run(["osascript", "-e", REBUILD], capture_output=True, timeout=60)
        for _ in range(30):
            time.sleep(2)
            if mail_count() == len(manifest["messages"]) and received_matches(manifest):
                break
        synced = received_matches(manifest)
    json.dump({"mail": {"account": manifest["account"], "count": len(manifest["messages"]), "synced": synced}}, sys.stdout)
    return 0 if synced else 1


def restore():
    clear()
    sync(0)
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "install":
        sys.exit(install(sys.argv[2]))
    if len(sys.argv) >= 2 and sys.argv[1] == "restore":
        sys.exit(restore())
    print(__doc__, file=sys.stderr)
    sys.exit(2)
