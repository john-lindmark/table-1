#!/usr/bin/env bash
# Trims what Claude sessions leave behind (every session builds iOS into its own scratchpad and simulator, and
# nothing removed them, so the disk filled every few days). Run hourly by launchd (install.sh):
#   - per-session Xcode build folders (scratchpad/dd*) with no file written for 6 hours (2 when under 30 GB free);
#   - booted T1-* simulators up for 6+ hours with no app installed in that time are shut down (a session that
#     builds again reinstalls, and simctl boots it again);
#   - shut-down T1-* simulators unused for 48 hours (24 when under 30 GB free) are deleted.
# T1-Tests (./test.sh full) is never touched. Nothing outside those folders and T1-* simulators is.
#   tools/cleanup/trim.sh          trim now
#   tools/cleanup/trim.sh --dry    say what it would do, change nothing
set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
DRY=${1:-}
SCRATCH=/private/tmp/claude-501
DEVICES="$HOME/Library/Developer/CoreSimulator/Devices"
LOG="$HOME/Library/Logs/Table1Trim.log"

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }
FREE=$(free_gb)
if [ "$FREE" -lt 30 ]; then BUILD_MIN=120; SIM_DEL_MIN=1440; else BUILD_MIN=360; SIM_DEL_MIN=2880; fi
IDLE_MIN=360

say() { if [ "$DRY" = --dry ]; then echo "would $*"; else echo "$(date '+%F %T') $*" >>"$LOG"; fi; }
act() { [ "$DRY" = --dry ] || "$@"; }

# Build folders.
for d in "$SCRATCH"/*/*/scratchpad/dd*; do
  [ -d "$d" ] || continue
  [ -n "$(find "$d" -mmin -$BUILD_MIN -print -quit 2>/dev/null)" ] && continue
  say "remove $(du -sh "$d" 2>/dev/null | cut -f1) $d"
  act rm -rf "$d"
done

# Simulators: name, state, udid of every T1-* device but T1-Tests.
sims=$(xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"].startswith("T1-") and d["name"] != "T1-Tests":
            print(d["name"], d["state"], d["udid"], sep="\t")')

# Minutes since each booted simulator's launchd_sim started (ps etime is [[dd-]hh:]mm:ss).
uptime_min() {
  ps -axo etime=,command= | awk -v u="$1" '$0 ~ "launchd_sim" && $0 ~ u {print $1; exit}' |
    awk -F'[-:]' '{n=NF; s=$n + 60*$(n-1); if (n>=3) s+=3600*$(n-2); if (n>=4) s+=86400*$(n-3); print int(s/60)}'
}

while IFS=$'\t' read -r name state udid; do
  [ -n "$udid" ] || continue
  dir="$DEVICES/$udid"
  if [ "$state" = Booted ]; then
    up=$(uptime_min "$udid"); [ -n "$up" ] || continue
    [ "$up" -lt $IDLE_MIN ] && continue
    [ -n "$(find "$dir/data/Containers/Bundle/Application" -maxdepth 2 -name '*.app' -mmin -$IDLE_MIN -print -quit 2>/dev/null)" ] && continue
    say "shut down $name ($udid), up $((up / 60)) h with no install"
    act xcrun simctl shutdown "$udid"
  elif [ "$state" = Shutdown ]; then
    [ -n "$(find "$dir" -mmin -$SIM_DEL_MIN -print -quit 2>/dev/null)" ] && continue
    say "delete $name ($udid) $(du -sh "$dir" 2>/dev/null | cut -f1)"
    act xcrun simctl delete "$udid"
  fi
done <<<"$sims"

[ "$DRY" = --dry ] && echo "free: ${FREE} GB" || echo "$(date '+%F %T') free ${FREE} → $(free_gb) GB" >>"$LOG"
