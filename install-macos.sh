#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "$0")" && pwd)"
MACOS_DIRECTORY="${SCRIPT_DIRECTORY}/macos"
PRODUCT_NAME="画境"
LEGACY_PRODUCT_NAME="Grsai Canvas"
SOURCE_APP="${MACOS_DIRECTORY}/.build/app/${PRODUCT_NAME}.app"

if [[ -n "${GRSAI_INSTALL_DIRECTORY:-}" ]]; then
    INSTALL_DIRECTORY="${GRSAI_INSTALL_DIRECTORY}"
else
    DESKTOP_DIRECTORY="$(/usr/bin/osascript -e 'POSIX path of (path to desktop folder)')"
    INSTALL_DIRECTORY="${DESKTOP_DIRECTORY%/}"
fi

if [[ "${INSTALL_DIRECTORY}" != /* ]]; then
    echo "安装目录必须是绝对路径：${INSTALL_DIRECTORY}" >&2
    exit 2
fi

/bin/mkdir -p "${INSTALL_DIRECTORY}"
"${MACOS_DIRECTORY}/scripts/build-app.sh" release

if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "构建产物不存在：${SOURCE_APP}" >&2
    exit 3
fi

STAGING_DIRECTORY="$(/usr/bin/mktemp -d "${INSTALL_DIRECTORY}/.grsai-canvas-install.XXXXXX")"
TARGET_APP="${INSTALL_DIRECTORY}/${PRODUCT_NAME}.app"
LEGACY_TARGET_APP="${INSTALL_DIRECTORY}/${LEGACY_PRODUCT_NAME}.app"

# 只清理本次 mktemp 创建的受控暂存目录。
cleanup() {
    if [[ -n "${STAGING_DIRECTORY:-}" && -d "${STAGING_DIRECTORY}" ]]; then
        /bin/rm -rf -- "${STAGING_DIRECTORY}"
    fi
}

trap cleanup EXIT INT TERM

STAGED_APP="${STAGING_DIRECTORY}/${PRODUCT_NAME}.app"
/usr/bin/ditto "${SOURCE_APP}" "${STAGED_APP}"

# 关闭旧版本并清理中英文同名应用，确保桌面只保留当前版本。
/usr/bin/osascript -e 'tell application id "ai.grsai.canvas" to quit' 2>/dev/null || true
for APP_PATH in "${TARGET_APP}" "${LEGACY_TARGET_APP}"; do
    if [[ -e "${APP_PATH}" || -L "${APP_PATH}" ]]; then
        /bin/rm -rf -- "${APP_PATH}"
    fi
done

if ! /bin/mv "${STAGED_APP}" "${TARGET_APP}"; then
    echo "安装失败。" >&2
    exit 4
fi

echo "安装完成：${TARGET_APP}"
/usr/bin/open -na "${TARGET_APP}"
echo "已启动：${TARGET_APP}"
