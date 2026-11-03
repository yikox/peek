#!/bin/bash
# 生成 AppIcon.icns：tools/make_icon.swift 画 1024 PNG → sips 缩各档 → iconutil 打包
# 用法: ./tools/make_icns.sh [输出路径]   （默认 build/AppIcon.icns）
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/AppIcon.icns}"
TMP="build/icon-gen"
ICONSET="build/AppIcon.iconset"

rm -rf "$TMP" "$ICONSET"
mkdir -p "$TMP" "$ICONSET"

swift tools/make_icon.swift "$TMP" >/dev/null
SRC="$TMP/icon_1024.png"
[ -f "$SRC" ] || { echo "FAIL 图标 PNG 没生成"; exit 1; }

for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
cp "$SRC" "$ICONSET/icon_512x512@2x.png"

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "icon: $OUT ($(du -h "$OUT" | cut -f1))"
