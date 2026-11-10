#!/bin/sh
# Runs INSIDE the disposable benchmark VM only (SIP off).
# usage: grant_ae.sh <absolute-binary-path>...
# Gives a binary that is its own responsible process (Pippin disclaims its
# parent) the same Automation grants that ssh sessions already hold, by copying
# the approved sshd rows for each target app.
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
for client in "$@"; do
  sqlite3 "$DB" "DELETE FROM access WHERE service='kTCCServiceAppleEvents' AND client='$client';
  INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags)
  SELECT service, '$client', 1, 2, auth_reason, auth_version, NULL, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags FROM access
  WHERE service='kTCCServiceAppleEvents' AND client='/usr/libexec/sshd-keygen-wrapper' AND auth_value=2;"
done
killall tccd 2>/dev/null
sqlite3 "$DB" "select client, auth_value, indirect_object_identifier from access where service='kTCCServiceAppleEvents'"
