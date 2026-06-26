#!/bin/bash
# Bundle the BreathDebugApp executable into a proper macOS .app: it gets a real Dock identity and,
# crucially, a copy of the breath palette so it runs without a working directory. Audio output needs
# no special entitlement, so the bundle is a convenience (not a requirement) compared to `swift run`.
#
# Usage:  scripts/make-debug-app.sh   ->   builds dist/BreathDebug.app and prints how to run it.
# Output lands in dist/ (not the hidden .build/) so it's visible and double-clickable in Finder.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="BreathDebug"
EXEC_NAME="breath-debug"
PLIST="Sources/BreathDebugApp/Resources/Info.plist"
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
# Bundle the palette so the app finds it via Bundle.main even when launched with no working directory.
cp -R "${ASSETS}" "${APP_DIR}/Contents/Resources/breaths"

# Ad-hoc sign so the bundle identity is stable across rebuilds.
echo "==> codesign --force --sign - ${APP_DIR}"
codesign --force --sign - "${APP_DIR}"

echo
echo "Built ${APP_DIR}"
echo "Run it with:   open ${APP_DIR}"
