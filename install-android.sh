#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "$0")" && pwd)"
ANDROID_DIRECTORY="${SCRIPT_DIRECTORY}/android"
APK_PATH="${ANDROID_DIRECTORY}/app/build/outputs/apk/debug/app-debug.apk"

# 优先使用 Android Studio 自带的 JDK 21，确保 Kotlin 与 Java 的 JVM 目标一致。
if [[ -z "${JAVA_HOME:-}" && -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    export PATH="${JAVA_HOME}/bin:${PATH}"
fi

# 自动识别本机 Android SDK，便于在干净终端中直接执行安装脚本。
if [[ -z "${ANDROID_SDK_ROOT:-}" && -d "${HOME}/Library/Android/sdk" ]]; then
    export ANDROID_SDK_ROOT="${HOME}/Library/Android/sdk"
fi
if [[ -z "${ANDROID_HOME:-}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_HOME="${ANDROID_SDK_ROOT}"
fi

if [[ -x "${ANDROID_DIRECTORY}/gradlew" ]]; then
    GRADLE_COMMAND="${ANDROID_DIRECTORY}/gradlew"
elif command -v gradle >/dev/null 2>&1; then
    GRADLE_COMMAND="$(command -v gradle)"
else
    echo "未找到 Gradle。请使用 Android Studio 打开 android/，或安装 Gradle 后重试。" >&2
    exit 2
fi

"${GRADLE_COMMAND}" -p "${ANDROID_DIRECTORY}" :app:assembleDebug

if [[ ! -f "${APK_PATH}" ]]; then
    echo "APK 构建完成，但未找到：${APK_PATH}" >&2
    exit 3
fi

echo "APK 已生成：${APK_PATH}"

if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
    adb install -r "${APK_PATH}"
    echo "已安装到当前 Android 设备。"
else
    echo "未检测到 adb 设备，已跳过设备安装。"
fi
