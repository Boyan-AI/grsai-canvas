#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "$0")" && pwd)"
PRODUCT_NAME="Grsai Canvas"
SOURCE_APP="${SCRIPT_DIRECTORY}/.build/app/${PRODUCT_NAME}.app"

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
"${SCRIPT_DIRECTORY}/scripts/build-app.sh" release

if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "构建产物不存在：${SOURCE_APP}" >&2
    exit 3
fi

STAGING_DIRECTORY="$(/usr/bin/mktemp -d "${INSTALL_DIRECTORY}/.grsai-canvas-install.XXXXXX")"
TARGET_APP="${INSTALL_DIRECTORY}/${PRODUCT_NAME}.app"
BACKUP_APP=""

# 只清理本次 mktemp 创建的受控暂存目录。
cleanup() {
    if [[ -n "${STAGING_DIRECTORY:-}" && -d "${STAGING_DIRECTORY}" ]]; then
        /bin/rm -rf -- "${STAGING_DIRECTORY}"
    fi
}

trap cleanup EXIT INT TERM

STAGED_APP="${STAGING_DIRECTORY}/${PRODUCT_NAME}.app"
/usr/bin/ditto "${SOURCE_APP}" "${STAGED_APP}"

if [[ -e "${TARGET_APP}" || -L "${TARGET_APP}" ]]; then
    TIMESTAMP="$(/bin/date '+%Y%m%d-%H%M%S')"
    BACKUP_APP="${INSTALL_DIRECTORY}/${PRODUCT_NAME}.backup-${TIMESTAMP}.app"
    BACKUP_INDEX=1
    while [[ -e "${BACKUP_APP}" || -L "${BACKUP_APP}" ]]; do
        BACKUP_APP="${INSTALL_DIRECTORY}/${PRODUCT_NAME}.backup-${TIMESTAMP}-${BACKUP_INDEX}.app"
        (( BACKUP_INDEX += 1 ))
    done
    /bin/mv "${TARGET_APP}" "${BACKUP_APP}"
fi

if ! /bin/mv "${STAGED_APP}" "${TARGET_APP}"; then
    if [[ -n "${BACKUP_APP}" && ! -e "${TARGET_APP}" ]]; then
        /bin/mv "${BACKUP_APP}" "${TARGET_APP}"
    fi
    echo "安装失败，已尝试恢复原版本。" >&2
    exit 4
fi

echo "安装完成：${TARGET_APP}"
if [[ -n "${BACKUP_APP}" ]]; then
    echo "旧版本已备份：${BACKUP_APP}"
fi
