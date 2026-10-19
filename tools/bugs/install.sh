#!/usr/bin/env bash
# Installs (or removes) the fix runner's launchd job: tools/bugs/runner.sh every 5 minutes while you're logged in.
#   tools/bugs/install.sh            install / update
#   tools/bugs/install.sh remove     uninstall
#   touch ~/.table1-bugs/paused      pause without uninstalling (rm to resume)
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
LABEL=site.table1.bug-runner
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = remove ]; then rm -f "$PLIST"; echo "removed $LABEL"; exit 0; fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Table1Bugs"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$REPO/tools/bugs/runner.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Table1Bugs/launchd.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Table1Bugs/launchd.err</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (every 5 min). Check: tools/bugs/runner.sh --dry"
