#!/bin/sh
# Runs INSIDE the disposable benchmark VM only (SIP is off in the Cirrus image).
# Grants a client path the data permissions the benchmark needs.
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
for client in "$@"; do
  for svc in kTCCServiceCalendar kTCCServiceReminders kTCCServiceAddressBook; do
    sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags) VALUES ('$svc', '$client', 1, 2, 4, 1, 'UNUSED', 0);"
  done
done
sqlite3 "$DB" "select service, client, auth_value from access where service in ('kTCCServiceCalendar','kTCCServiceReminders','kTCCServiceAddressBook')"
