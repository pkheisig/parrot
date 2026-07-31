#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/dist/Parrot.app"
INSTALLED_APP="/Applications/Parrot.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
EXPECTED_BUNDLE_ID="com.pkheisig.parrot"
LEGACY_BUNDLE_ID="com.digimata.parrot"

cd "${ROOT_DIR}"

SOURCE_BUNDLE_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${ROOT_DIR}/App/Info.plist"
)"
if [ "${SOURCE_BUNDLE_ID}" != "${EXPECTED_BUNDLE_ID}" ]; then
    echo "App/Info.plist bundle identifier '${SOURCE_BUNDLE_ID}' does not match '${EXPECTED_BUNDLE_ID}'" >&2
    exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

/usr/bin/ditto "${BIN_DIR}/parrot" "${MACOS_DIR}/parrot"
/usr/bin/ditto "${BIN_DIR}/whisper.framework" "${FRAMEWORKS_DIR}/whisper.framework"
/usr/bin/ditto "${ROOT_DIR}/App/Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/bin/ditto "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${RESOURCES_DIR}/THIRD_PARTY_NOTICES.md"
chmod 755 "${MACOS_DIR}/parrot"
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/parrot"

# Apply a local ad-hoc signature so macOS treats the assembled directory as a
# signed application bundle.
/usr/bin/codesign --force --deep --sign - "${APP_BUNDLE}"

# Never replace an unrelated application that happens to share the filename.
if [ -d "${INSTALLED_APP}" ]; then
    INSTALLED_BUNDLE_ID="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${INSTALLED_APP}/Contents/Info.plist" 2>/dev/null || true
    )"
    if [ "${INSTALLED_BUNDLE_ID}" != "${EXPECTED_BUNDLE_ID}" ] \
        && [ "${INSTALLED_BUNDLE_ID}" != "${LEGACY_BUNDLE_ID}" ]; then
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

# Register the new bundle identity without launching the application. This lets
# tccutil resolve it while keeping status-item ownership out of the build host.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"${LSREGISTER}" -f "${INSTALLED_APP}"

# Ad-hoc signing produces a new code requirement after each rebuild. Reset the
# old consent records so System Settings cannot misleadingly show an enabled
# toggle for a binary that TCC will reject.
/usr/bin/tccutil reset Accessibility "${EXPECTED_BUNDLE_ID}"
/usr/bin/tccutil reset Microphone "${EXPECTED_BUNDLE_ID}"

echo "Built ${APP_BUNDLE}"
echo "Installed ${INSTALLED_APP}"
echo "Reset Accessibility and Microphone permissions"
echo "Not launched: open ${INSTALLED_APP} manually so macOS attributes its menu-bar item to Parrot."
