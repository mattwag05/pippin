#!/bin/bash
# Installs every benchmarked competitor at its pin (docs/competitive/field.md,
# tools.lock.json) into ~/bench-tools/<short-name>/.
#
# Run this INSIDE the disposable benchmark VM only, never on a personal Mac:
# it downloads and runs third-party code. No sudo, nothing outside the tools
# directory except package-manager caches. Idempotent: a tool whose marker
# file exists is skipped. Prints one line per tool: "<name> ok|failed <seconds>s".
#
# Needs: git, curl, node 20+, npm, python3.13+ (as python3.14 or PYTHON=...),
# Swift 6.x (Xcode), all already present in the VM image.
set -euo pipefail

T="${BENCH_TOOLS:-$HOME/bench-tools}"
PY="${PYTHON:-python3.14}"
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p "$T/_logs"
GH=https://github.com

fetch() { curl -fsSL --retry 2 -o "$2" "$1"; }

# Verifies file $1 against the line for its basename in checksum file $2.
verify() { (cd "$(dirname "$1")" && grep " [*]\{0,1\}$(basename "$1")\$" "$2" | shasum -a 256 -c -); }

i_imsg() {  # release binary, checksum verified
  fetch "$GH/openclaw/imsg/releases/download/v0.21.0/imsg-macos.zip" imsg-macos.zip
  fetch "$GH/openclaw/imsg/releases/download/v0.21.0/SHA256SUMS" SHA256SUMS
  verify "$PWD/imsg-macos.zip" "$PWD/SHA256SUMS"
  unzip -oq imsg-macos.zip
}

i_remindctl() {  # release binary, checksum verified
  fetch "$GH/openclaw/remindctl/releases/download/v0.3.9/remindctl-macos.zip" remindctl-macos.zip
  fetch "$GH/openclaw/remindctl/releases/download/v0.3.9/checksums.txt" checksums.txt
  verify "$PWD/remindctl-macos.zip" "$PWD/checksums.txt"
  unzip -oq remindctl-macos.zip
}

i_reminders_cli() {  # release binary (the project publishes no checksum)
  fetch "$GH/keith/reminders-cli/releases/download/2.5.1/reminders.tar.gz" reminders.tar.gz
  tar -zxf reminders.tar.gz
}

i_memo() {  # README "manual installation" (pip install of the repo), in a venv, at the tag
  "$PY" -m venv venv
  venv/bin/pip install -q "git+$GH/antoniorodr/memo@v0.6.2"
}

i_sweetrb_mail() { npm install --silent --no-fund --no-audit --prefix "$PWD" apple-mail-mcp@2.20.55; }
i_sweetrb_notes() { npm install --silent --no-fund --no-audit --prefix "$PWD" apple-notes-mcp@2.16.1; }
i_apple_events() { npm install --silent --no-fund --no-audit --prefix "$PWD" mcp-server-apple-events@1.6.2; }

i_pf_mail() {  # README "pip install" route, in a venv
  "$PY" -m venv venv
  venv/bin/pip install -q mcp-apple-mail==3.3.0
}

i_mac_messages() {  # README uses uvx; same PyPI package, pip in a venv instead (no brew)
  "$PY" -m venv venv
  venv/bin/pip install -q mac-messages-mcp==1.1.0
}

i_apple_pim() {  # README "development installation": clone, ./setup.sh (build only, stays in the checkout)
  rm -rf src
  git clone -q --depth 1 --branch v3.19.2 "$GH/omarshahine/apple-pim" src
  (cd src && ./setup.sh)
}

i_imcp() {  # release app bundle, unpacked into the tools dir instead of /Applications
  fetch "$GH/mattt/iMCP/releases/download/1.8.3/iMCP.zip" iMCP.zip
  unzip -oq iMCP.zip
}

rc=0
for name in imsg remindctl reminders-cli memo sweetrb-mail pf-mail sweetrb-notes apple-events mac-messages apple-pim imcp; do
  dir="$T/$name"
  if [ -f "$dir/.installed" ]; then
    echo "$name ok 0s (already installed)"
    continue
  fi
  mkdir -p "$dir"
  start=$SECONDS
  if (cd "$dir" && "i_$(echo "$name" | tr - _)") >"$T/_logs/$name.log" 2>&1; then
    secs=$((SECONDS - start))
    echo "$secs" >"$dir/.installed"
    echo "$name ok ${secs}s"
  else
    echo "$name failed $((SECONDS - start))s (see $T/_logs/$name.log)"
    rc=1
  fi
done
exit $rc
