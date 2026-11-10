#!/bin/sh
# VM only, once per VM: a local mail server and Mail account, and the Voice Memos store (Amendment 4).
# Needs the VM booted WITH a display (`tart run pippin-bench`, not --no-graphics): Voice Memos will not
# launch without one. Never run this on a real Mac.
#
# Mail: Dovecot on 127.0.0.1 (ports 143 and 1143), no TLS, any password accepted, one Maildir. The Mail
# account `PippinBench` points at it. Nothing listens beyond localhost and nothing is ever sent.
#
# Mail ignores accounts made by AppleScript (they stay disabled and are never saved), so the account is added
# once through Mail's own Add Account sheet, in the VM's display (2026-11-10 this was driven with cliclick):
#   Mail > Add Account > choose from a list > Other Mail Account; Email bench@pippinbench.invalid, any password;
#   Sign In; Incoming and Outgoing Mail Server 127.0.0.1; Continue past the plaintext warning; Next;
#   leave only Mail ticked (untick Notes, so the Notes fixture keeps one account); Done;
#   "Don't protect Mail activity"; Continue. This script then renames the account to PippinBench.
# Voice Memos: opened once so it creates its own CloudRecordings.db; fixtures/make_memos.py fills it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
limit() { secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" != "1" ]; then
  echo "mail-setup.sh: this is not a virtual machine; refusing" >&2
  exit 2
fi
export PATH="/opt/homebrew/bin:$PATH" HOMEBREW_NO_AUTO_UPDATE=1

[ -x /opt/homebrew/opt/dovecot/sbin/dovecot ] || brew install dovecot
mkdir -p "$HOME/bench-mail/run" "$HOME/bench-mail/state" "$HOME/bench-mail/home" "$HOME/bench-mail/maildir/cur" "$HOME/bench-mail/maildir/new" "$HOME/bench-mail/maildir/tmp"
sed "s#/Users/admin#$HOME#g; s#= admin\$#= $(id -un)#" "$HERE/dovecot.conf" > "$HOME/bench-mail/dovecot.conf"
pgrep -f "[s]bin/dovecot -c" >/dev/null || sudo -n /opt/homebrew/opt/dovecot/sbin/dovecot -c "$HOME/bench-mail/dovecot.conf" </dev/null >/dev/null 2>&1
sleep 5

accounts=$(limit 30 osascript -e 'tell application "Mail" to name of every account' || true)
case "$accounts" in
  *PippinBench*) ;;
  *Pippinbench*) limit 30 osascript -e 'tell application "Mail" to set name of account "Pippinbench" to "PippinBench"' ;;
  *) echo "mail-setup.sh: add the Mail account by hand as described at the top of this file, then run it again" >&2; exit 1 ;;
esac

R="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
if [ ! -f "$R/CloudRecordings.db" ]; then
  open -a VoiceMemos
  n=0; while [ ! -f "$R/CloudRecordings.db" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
  sleep 3
  pkill -x VoiceMemos || true
fi
echo "mail-setup: Mail account PippinBench on 127.0.0.1:1143; Voice Memos store present: $([ -f "$R/CloudRecordings.db" ] && echo yes || echo no)"
