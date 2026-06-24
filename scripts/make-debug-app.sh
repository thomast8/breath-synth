#!/bin/bash
# Bundle the SensorDebugApp executable into a proper macOS .app so it gets its own bundle identity
# (and therefore a stable Bluetooth/TCC permission grant, instead of inheriting the terminal's).
#
# Usage:  scripts/make-debug-app.sh   ->   builds .build/SensorDebug.app and prints how to run it.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SensorDebug"
EXEC_NAME="sensor-debug"
PLIST="Sources/SensorDebugApp/Resources/Info.plist"
APP_DIR=".build/${APP_NAME}.app"

echo "==> swift build -c release --product ${EXEC_NAME}"
swift build -c release --product "${EXEC_NAME}"

BIN_PATH="$(swift build -c release --product "${EXEC_NAME}" --show-bin-path)/${EXEC_NAME}"

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp "${PLIST}" "${APP_DIR}/Contents/Info.plist"

# Ad-hoc sign so the TCC identity is stable across rebuilds (unsigned re-prompts every time).
echo "==> codesign --force --sign - ${APP_DIR}"
codesign --force --sign - "${APP_DIR}"

echo
echo "Built ${APP_DIR}"
echo "Run it with:   open ${APP_DIR}"
echo "(First launch prompts for Bluetooth; the grant sticks to ${APP_NAME}.app itself.)"
