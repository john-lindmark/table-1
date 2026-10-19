#!/usr/bin/env bash
# Installs (or removes) the fix runner's launchd job: `runner.sh --poll` every 5 minutes while you're logged in.
# launchd jobs can't read ~/Documents, so the poll runs from copies in ~/.table1-bugs/ (rerun this after changing
# runner.sh or bugs.py) and hands each run to Terminal, which can.
#   tools/bugs/install.sh            install / update
#   tools/bugs/install.sh remove     uninstall
#   touch ~/.table1-bugs/paused      pause without uninstalling (rm to resume)
# Terminal → Settings → Profiles → Shell → "When the shell exits: Close if the shell exited cleanly" closes each
# run's window when it finishes.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
STATE="$HOME/.table1-bugs"
LABEL=site.table1.bug-runner
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = remove ]; then rm -f "$PLIST"; echo "removed $LABEL"; exit 0; fi

mkdir -p "$STATE" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Table1Bugs"
cp "$REPO/tools/bugs/runner.sh" "$REPO/tools/bugs/bugs.py" "$STATE/"
echo "$REPO" >"$STATE/repo"
cat >"$STATE/run.command" <<EOF
#!/bin/bash
# Opened in Terminal by the launchd poll (tools/bugs/runner.sh --poll).
exec /bin/bash "$REPO/tools/bugs/runner.sh" --run "\$(cat "$STATE/next-level" 2>/dev/null || echo S4)"
EOF
chmod +x "$STATE/runner.sh" "$STATE/bugs.py" "$STATE/run.command"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$STATE/runner.sh</string><string>--poll</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Table1Bugs/launchd.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Table1Bugs/launchd.err</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (every 5 min). Check: tools/bugs/runner.sh --dry"
