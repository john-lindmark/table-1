#!/bin/zsh
# One time: makes the Play upload key and keystore.properties (both stay out of git).
# The key lives in ~/.android/table1-upload.jks. Back it up with its password in your
# password manager; if it's lost, Play Console can reset the upload key (takes a few days).
set -e
cd "$(dirname "$0")/.."
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}
KS="$HOME/.android/table1-upload.jks"
if [[ -e "$KS" ]]; then echo "$KS already exists; not overwriting."; exit 1; fi

read -rs "PW?Choose a password for the upload key (6+ characters): "; echo
read -rs "PW2?Again: "; echo
[[ "$PW" == "$PW2" && ${#PW} -ge 6 ]] || { echo "Passwords differ or too short."; exit 1; }

mkdir -p "$HOME/.android"
"$JAVA_HOME/bin/keytool" -genkeypair -v -keystore "$KS" -alias upload -keyalg RSA -keysize 4096 \
  -validity 10000 -storepass "$PW" -keypass "$PW" -dname "CN=Table 1, O=Table 1, C=US"

cat > keystore.properties <<PROPS
storeFile=$KS
storePassword=$PW
keyAlias=upload
keyPassword=$PW
PROPS
chmod 600 keystore.properties "$KS"

echo
echo "Upload key fingerprints (add the SHA-1 to Google Cloud as an Android OAuth client):"
"$JAVA_HOME/bin/keytool" -list -v -keystore "$KS" -storepass "$PW" -alias upload | grep -E "SHA1|SHA256"
