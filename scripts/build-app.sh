#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/dist/Parrot.app"
INSTALLED_APP="/Applications/Parrot.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
EXPECTED_BUNDLE_ID="com.digimata.parrot"

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

# Never replace an unrelated application that happens to share the filename.
if [ -d "${INSTALLED_APP}" ]; then
    INSTALLED_BUNDLE_ID="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${INSTALLED_APP}/Contents/Info.plist" 2>/dev/null || true
    )"
    if [ "${INSTALLED_BUNDLE_ID}" != "${EXPECTED_BUNDLE_ID}" ]; then
        echo "Refusing to replace ${INSTALLED_APP}: unexpected bundle identifier '${INSTALLED_BUNDLE_ID}'" >&2
        exit 1
    fi
fi

# A running executable can outlive its replaced bundle. Stop the installed
# instance so the next launch always runs the binary that was just built.
RUNNING_PATTERN="^${INSTALLED_APP}/Contents/MacOS/parrot$"
if /usr/bin/pgrep -f "${RUNNING_PATTERN}" >/dev/null 2>&1; then
    /usr/bin/pkill -TERM -f "${RUNNING_PATTERN}"
    for _ in 1 2 3 4 5; do
        if ! /usr/bin/pgrep -f "${RUNNING_PATTERN}" >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
fi

rm -rf "${INSTALLED_APP}"
/usr/bin/ditto "${APP_BUNDLE}" "${INSTALLED_APP}"

/usr/bin/codesign --verify --deep --strict "${INSTALLED_APP}"

# Ad-hoc signing produces a new code requirement after each rebuild. Reset the
# old consent records so System Settings cannot misleadingly show an enabled
# toggle for a binary that TCC will reject.
/usr/bin/tccutil reset Accessibility "${EXPECTED_BUNDLE_ID}"
/usr/bin/tccutil reset Microphone "${EXPECTED_BUNDLE_ID}"

/usr/bin/open -a "${INSTALLED_APP}"

echo "Built ${APP_BUNDLE}"
echo "Installed ${INSTALLED_APP}"
echo "Reset Accessibility and Microphone permissions"
echo "Launched ${INSTALLED_APP}"
