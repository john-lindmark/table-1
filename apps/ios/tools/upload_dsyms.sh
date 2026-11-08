#!/bin/sh
# Uploads an archive's dSYMs to Sentry (project table-1-ios), so iOS crash and hang reports show function names.
# Run by the "Table 1" scheme's archive post-action (Xcode sets ARCHIVE_DSYMS_PATH), or by hand with a dSYMs folder:
#   apps/ios/tools/upload_dsyms.sh ~/Library/Developer/Xcode/Archives/<day>/<archive>.xcarchive/dSYMs
# Needs sentry-cli (brew install getsentry/tools/sentry-cli) and an org auth token in the Keychain, service
# "Table 1 Sentry". It never fails an archive: anything missing is written to the log and skipped.
dsyms="${1:-$ARCHIVE_DSYMS_PATH}"
log="$HOME/Library/Logs/Table1/dsym-upload.log"
mkdir -p "$(dirname "$log")"
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$log"; }

cli=$(command -v sentry-cli || echo /opt/homebrew/bin/sentry-cli)
if [ ! -x "$cli" ]; then say "sentry-cli not installed: dSYMs not uploaded ($dsyms)"; exit 0; fi
if [ -z "$dsyms" ] || [ ! -d "$dsyms" ]; then say "no dSYMs folder: '$dsyms'"; exit 0; fi
token=$(security find-generic-password -s "Table 1 Sentry" -w 2>/dev/null)
if [ -z "$token" ]; then say "no Sentry token in the Keychain (service 'Table 1 Sentry'): dSYMs not uploaded"; exit 0; fi

say "uploading $dsyms"
if SENTRY_AUTH_TOKEN="$token" "$cli" debug-files upload --org table-1 --project table-1-ios "$dsyms" >>"$log" 2>&1; then
  say "uploaded"
else
  say "upload failed (see above): run this script again with the dSYMs folder"
fi
exit 0
