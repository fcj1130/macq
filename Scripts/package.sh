#!/bin/bash
# 打包 Release 版 MacQ.app 为 DMG（含拖入 Applications 的软链）
# 用法：./Scripts/package.sh [版本号]   不传则读 app 的 Info.plist，再兜底 1.0
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=Release
APP="build/Build/Products/$CONFIGURATION/MacQ.app"
OUT=dist

echo "── 1/3 Release 构建"
xcodegen generate >/dev/null 2>&1 || echo "⚠ xcodegen 失败（多半 GitHub 超时），用现有 macq.xcodeproj 继续"
xcodebuild -project macq.xcodeproj -scheme macq \
    -configuration "$CONFIGURATION" -derivedDataPath build build -quiet 2>&1 \
    | sed '/exit code 0 but produced no further output/d'   # 过滤 xcodebuild 幽灵报错（退出码 0 且构建实际成功）
[ -d "$APP" ] || { echo "✗ 找不到 $APP"; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "✗ 签名校验失败"; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)}"
VERSION="${VERSION:-1.0}"

echo "── 2/3 暂存 MacQ $VERSION + /Applications 软链"
STAGE=$(mktemp -d /tmp/macq-dmg.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/MacQ.app"
ln -s /Applications "$STAGE/Applications"

echo "── 3/3 生成 DMG"
mkdir -p "$OUT"
DMG="$OUT/MacQ-$VERSION.dmg"
# hdiutil create 在新系统标记 deprecated；diskutil image create from 是官方替代
# （已在本机验证 UDZO / 软链 / CRC 与 hdiutil 等价）。diskutil 没有 -ov，先删旧文件。
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName "MacQ" "$STAGE" "$DMG" >/dev/null 2>&1
hdiutil verify "$DMG" >/dev/null && echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
