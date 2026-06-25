#!/bin/bash
# Bundle the BreathEnrollApp executable into a proper macOS .app: it gets a real Dock identity, a
# copy of the reference breath palette (for guided playback), and — crucially — is codesigned WITH
# the microphone entitlement so input capture works. Unlike the debug app (audio output only, runs
# unsigned), enrollment needs mic INPUT, which requires both NSMicrophoneUsageDescription (embedded
# in Info.plist) and a real codesign step carrying the audio-input entitlement.
#
# Usage:  scripts/make-enroll-app.sh   ->   builds dist/BreathEnroll.app and prints how to run it.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="BreathEnroll"
EXEC_NAME="breath-enroll"
PLIST="Sources/BreathEnrollApp/Resources/Info.plist"
ENTITLEMENTS="Sources/BreathEnrollApp/Resources/BreathEnroll.entitlements"
ASSETS="Assets/breaths"
APP_DIR="dist/${APP_NAME}.app"

echo "==> swift build -c release --product ${EXEC_NAME}"
swift build -c release --product "${EXEC_NAME}"

BIN_PATH="$(swift build -c release --product "${EXEC_NAME}" --show-bin-path)/${EXEC_NAME}"

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp "${PLIST}" "${APP_DIR}/Contents/Info.plist"
# Bundle the reference palette so the app can play gold references via Bundle.main.
cp -R "${ASSETS}" "${APP_DIR}/Contents/Resources/breaths"

# Ad-hoc sign WITH the microphone entitlement so the first input-node access is allowed once the
# user grants the TCC prompt. (Audio output needs no entitlement; input does.)
echo "==> codesign --force --sign - --entitlements ${ENTITLEMENTS} ${APP_DIR}"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_DIR}"

echo
echo "Built ${APP_DIR}"
echo "Run it with:   open ${APP_DIR}"
