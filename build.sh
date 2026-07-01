#!/bin/bash
# 以 Release 配置打包 iFan，并安装/替换到「应用程序」目录。
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="iFan.xcodeproj"
SCHEME="iFan"
CONFIG="Release"
DERIVED="build"
DEST="$HOME/Applications"

echo "==> 退出正在运行的 iFan（如有）"
pkill -x iFan 2>/dev/null || true

echo "==> 清理并以 ${CONFIG} 配置编译"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" clean build

BUILT_APP="${DERIVED}/Build/Products/${CONFIG}/iFan.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "构建产物不存在：${BUILT_APP}" >&2
  exit 1
fi

echo "==> 替换 ${DEST}/iFan.app（需要管理员权限）"
rm -rf "${DEST}/iFan.app" 2>/dev/null || true
cp -R "$BUILT_APP" "$DEST/"

echo "==> 完成：${DEST}/iFan.app"
echo "可执行：open \"${DEST}/iFan.app\""
