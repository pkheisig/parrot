#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/dist/Parrot.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

cd "${ROOT_DIR}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

/usr/bin/ditto "${BIN_DIR}/parrot" "${MACOS_DIR}/parrot"
/usr/bin/ditto "${ROOT_DIR}/App/Info.plist" "${CONTENTS_DIR}/Info.plist"
chmod 755 "${MACOS_DIR}/parrot"

# Apply a local ad-hoc signature so macOS treats the assembled directory as a
# signed application bundle.
/usr/bin/codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Built ${APP_BUNDLE}"
