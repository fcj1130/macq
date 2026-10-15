#!/bin/bash
# 从 temp/icon.png 生成 AppIcon.appiconset（可重复执行）
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="temp/icon.png"
OUT="Resources/Assets.xcassets/AppIcon.appiconset"

[ -f "$SRC" ] || { echo "错误：缺少 $SRC"; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SRC" --out "$OUT/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SRC" --out "$OUT/icon_${size}x${size}@2x.png" >/dev/null
done

cat > "$OUT/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

# Assets 根目录 Contents.json（首次生成）
ASSETS="Resources/Assets.xcassets"
if [ ! -f "$ASSETS/Contents.json" ]; then
    cat > "$ASSETS/Contents.json" <<'EOF'
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF
fi

echo "✓ AppIcon 已生成：$OUT"
