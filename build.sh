#!/bin/bash
# 默认仅以 Release 配置编译 iFan；安装和启动必须显式指定。
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="iFan.xcodeproj"
SCHEME="iFan"
CONFIG="Release"
DERIVED="build"
INSTALL_DIR=""
RUN_AFTER_BUILD=false

usage() {
  echo "用法："
  echo "  bash build.sh"
  echo "  bash build.sh --run"
  echo "  bash build.sh --install <目标目录> [--run]"
  echo
  echo "默认仅编译，产物位于 build/Build/Products/Release/iFan.app。"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install)
      if [ "$#" -lt 2 ]; then
        echo "--install 需要指定目标目录" >&2
        usage >&2
        exit 2
      fi
      INSTALL_DIR="${2%/}"
      shift 2
      ;;
    --run)
      RUN_AFTER_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

echo "==> 清理并以 ${CONFIG} 配置编译"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" clean build

BUILT_APP="${DERIVED}/Build/Products/${CONFIG}/iFan.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "构建产物不存在：${BUILT_APP}" >&2
  exit 1
fi

APP_TO_RUN="$BUILT_APP"

if [ -n "$INSTALL_DIR" ]; then
  if [ "$INSTALL_DIR" = "/" ] || [ ! -d "$INSTALL_DIR" ]; then
    echo "安装目标必须是已存在的具体目录：$INSTALL_DIR" >&2
    exit 2
  fi

  INSTALLED_APP="${INSTALL_DIR}/iFan.app"
  echo "==> 退出正在运行的 iFan（如有）"
  pkill -x iFan 2>/dev/null || true
  echo "==> 安装到 ${INSTALLED_APP}"
  rm -rf "$INSTALLED_APP"
  cp -R "$BUILT_APP" "$INSTALL_DIR/"
  APP_TO_RUN="$INSTALLED_APP"
fi

echo "==> 构建完成：${BUILT_APP}"

if [ "$RUN_AFTER_BUILD" = true ]; then
  if [ -z "$INSTALL_DIR" ]; then
    echo "==> 退出正在运行的 iFan（如有）"
    pkill -x iFan 2>/dev/null || true
  fi
  echo "==> 启动 ${APP_TO_RUN}"
  open "$APP_TO_RUN"
fi
