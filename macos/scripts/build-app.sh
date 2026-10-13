#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
CONFIGURATION="${1:-release}"
PRODUCT_NAME="画境"
BUNDLE_IDENTIFIER="ai.grsai.canvas"
BUILD_DIRECTORY="${PROJECT_DIRECTORY}/.build"
APP_DIRECTORY="${BUILD_DIRECTORY}/app/${PRODUCT_NAME}.app"
CONTENTS_DIRECTORY="${APP_DIRECTORY}/Contents"
MACOS_DIRECTORY="${CONTENTS_DIRECTORY}/MacOS"
RESOURCES_DIRECTORY="${CONTENTS_DIRECTORY}/Resources"
ICON_PATH="${PROJECT_DIRECTORY}/Assets/AppIcon.icns"

cd "${PROJECT_DIRECTORY}"
/usr/bin/xcrun swift build -c "${CONFIGURATION}" --product GrsaiCanvasApp

EXECUTABLE_PATH="$(/usr/bin/xcrun swift build -c "${CONFIGURATION}" --show-bin-path)/GrsaiCanvasApp"

mkdir -p "${MACOS_DIRECTORY}" "${RESOURCES_DIRECTORY}"
cp "${EXECUTABLE_PATH}" "${MACOS_DIRECTORY}/GrsaiCanvasApp"
cp "${ICON_PATH}" "${RESOURCES_DIRECTORY}/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Clear dict" "${CONTENTS_DIRECTORY}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string zh_CN" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${PRODUCT_NAME}" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string GrsaiCanvasApp" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_IDENTIFIER}" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ${PRODUCT_NAME}" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "${CONTENTS_DIRECTORY}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "${CONTENTS_DIRECTORY}/Info.plist"

echo "已生成 ${APP_DIRECTORY}"
