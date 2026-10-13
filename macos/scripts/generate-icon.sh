#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
SOURCE_ICON="${1:-${PROJECT_DIRECTORY}/Assets/AppIconSource.png}"
OUTPUT_ICON="${2:-${PROJECT_DIRECTORY}/Assets/AppIcon.icns}"

if [[ ! -f "${SOURCE_ICON}" ]]; then
    echo "图标母图不存在：${SOURCE_ICON}" >&2
    exit 2
fi

PIXEL_WIDTH="$(/usr/bin/sips -g pixelWidth "${SOURCE_ICON}" | /usr/bin/awk '/pixelWidth/ {print $2}')"
PIXEL_HEIGHT="$(/usr/bin/sips -g pixelHeight "${SOURCE_ICON}" | /usr/bin/awk '/pixelHeight/ {print $2}')"
if [[ "${PIXEL_WIDTH}" != "${PIXEL_HEIGHT}" || "${PIXEL_WIDTH}" -lt 1024 ]]; then
    echo "图标母图必须是至少 1024×1024 的正方形 PNG。" >&2
    exit 3
fi

TEMPORARY_DIRECTORY="$(/usr/bin/mktemp -d /tmp/grsai-app-icon.XXXXXX)"
ICONSET_DIRECTORY="${TEMPORARY_DIRECTORY}/AppIcon.iconset"
MODULE_CACHE_DIRECTORY="${PROJECT_DIRECTORY}/.build/icon-module-cache"

# 只清理本次 mktemp 创建的图标暂存目录。
cleanup() {
    /bin/rm -rf -- "${TEMPORARY_DIRECTORY}"
}

trap cleanup EXIT INT TERM
/bin/mkdir -p "${ICONSET_DIRECTORY}" "${OUTPUT_ICON:h}" "${MODULE_CACHE_DIRECTORY}"
/usr/bin/env \
    CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIRECTORY}" \
    SWIFT_MODULECACHE_PATH="${MODULE_CACHE_DIRECTORY}" \
    /usr/bin/xcrun swift \
    "${SCRIPT_DIRECTORY}/render-iconset.swift" \
    "${SOURCE_ICON}" \
    "${ICONSET_DIRECTORY}" \
    "${OUTPUT_ICON}"
echo "已生成 ${OUTPUT_ICON}"
