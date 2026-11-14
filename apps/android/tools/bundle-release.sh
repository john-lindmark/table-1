#!/bin/zsh
# Builds the signed release bundle for Play Console (internal testing).
# versionCode = minutes since 1970, so every build uploads as newer (stays far below Play's 2.1e9 cap).
set -e
cd "$(dirname "$0")/.."
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}
[[ -f keystore.properties ]] || { echo "No keystore.properties: run tools/make-upload-key.sh first."; exit 1; }
grep -q "^T1_GOOGLE_WEB_CLIENT_ID=REPLACE_" gradle.properties && echo "Note: T1_GOOGLE_WEB_CLIENT_ID is still a placeholder, so Google sign-in is hidden in this build."
CODE=$(( $(date +%s) / 60 ))
./gradlew bundleRelease -PT1_VERSION_CODE=$CODE
OUT=app/build/outputs/bundle/release/app-release.aab
echo
echo "versionCode $CODE → $PWD/$OUT"
echo "Upload to internal testing: node tools/play-upload.mjs $OUT --notes <release notes .md>"
echo "(or by hand: Play Console → Test and release → Testing → Internal testing → Create new release)."
