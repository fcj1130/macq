#!/bin/bash
# 离屏渲染 + hitTest + OCR 探测 macq 的 UI（无需截屏/辅助功能权限）
#
#   ./Scripts/uidbg/probe.sh                      # 默认探针：结构 + 侧栏 + 整窗文字
#   ./Scripts/uidbg/probe.sh MyProbe.swift        # 自定义探针（内容替换 main.swift）
#
# 注意：macOS 材质（.regularMaterial / 侧栏毛玻璃）在离屏 cacheDisplay 下渲染为空白，
# 所以侧栏文字 OCR 不到属正常现象——用 hitTest 判断行是否存在、是否可点。
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
WORK="/tmp/macq-uidbg"
PROBE="${1:-$ROOT/Scripts/uidbg/probe-default.swift}"

# 滚轮 / 剪贴板探针会投递合成的输入事件：运行中的 macq 自己也会拦截滚轮、并把探针写入剪贴板的
# 测试内容记进你的真实历史，必须先停掉——否则结论是错的（跑完请自行重启 app）。
case "$PROBE" in
  *scroll*|*clipboard*)
    if pgrep -x -i macq >/dev/null; then
      echo "⚠︎  检测到运行中的 MacQ：会污染测量/真实历史，先停掉（跑完请自行重启 app）"
      pkill -x MacQ 2>/dev/null || true; pkill -x macq 2>/dev/null || true
      sleep 1
    fi
    ;;
esac

rm -rf "$WORK" && mkdir -p "$WORK/src"
cp -R "$ROOT/Sources/"* "$WORK/src/"
rm -f "$WORK/src/MacqApp.swift"          # 入口与探针的 main 冲突
cp "$PROBE" "$WORK/src/main.swift"
cp "$ROOT/Scripts/uidbg/probe-helpers.swift" "$WORK/src/"

# 应用资源（菜单栏图标）放到探针二进制旁边：Bundle.main 就能查到，
# 这样探针验的是线上同一条加载路径，而不是另写一套
find "$ROOT/Resources" -maxdepth 1 -name '*.png' -exec cp {} "$WORK/" \;

# 剥掉 #Preview（swiftc 直编不认这个宏）
python3 - "$WORK" <<'PY'
import re, sys, pathlib
for p in pathlib.Path(sys.argv[1], 'src').rglob('*.swift'):
    t = p.read_text()
    t = re.sub(r'#Preview\([^)]*\)\s*\{.*?\n\}\n', '', t, flags=re.S)
    t = re.sub(r'#Preview\s*\{.*?\n\}\n', '', t, flags=re.S)
    p.write_text(t)
PY

xcrun swiftc -o "$WORK/probe" $(find "$WORK/src" -name '*.swift')
"$WORK/probe"
