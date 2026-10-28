#!/usr/bin/env bash
# Installs (or removes) the hourly launchd job that runs trim.sh (old session builds, idle T1 simulators).
# launchd jobs can't read ~/Documents, so it runs a copy in ~/.table1-trim/ (rerun this after changing trim.sh).
#   tools/cleanup/install.sh            install / update
#   tools/cleanup/install.sh remove     uninstall
# Log: ~/Library/Logs/Table1Trim.log
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
STATE="$HOME/.table1-trim"
LABEL=site.table1.trim
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = remove ]; then rm -f "$PLIST"; echo "removed $LABEL"; exit 0; fi

mkdir -p "$STATE" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$REPO/tools/cleanup/trim.sh" "$STATE/"
chmod +x "$STATE/trim.sh"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$STATE/trim.sh</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Table1Trim.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Table1Trim.err</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (hourly). Check: tools/cleanup/trim.sh --dry; log ~/Library/Logs/Table1Trim.log"
