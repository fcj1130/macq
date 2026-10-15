#!/bin/bash
# 构建并启动 MacQ（改完代码跑这个即可看到最新 UI）
set -euo pipefail
cd "$(dirname "$0")/.."

pkill -x MacQ 2>/dev/null || true; pkill -x macq 2>/dev/null || true

# GitHub 超时常见；工程已在仓库里时继续用现成的
xcodegen generate >/dev/null 2>&1 || echo "⚠ xcodegen 失败（多半 GitHub 超时），用现有 macq.xcodeproj 继续"

xcodebuild -project macq.xcodeproj -scheme macq -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build build -quiet

open build/Build/Products/Debug/MacQ.app
echo "✓ MacQ 已启动"
