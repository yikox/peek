#!/bin/bash
# 打包成可双击运行的 Peek.app
# 用法: ./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/Peek.app"

swift build -c "$CONFIG" --disable-sandbox
BIN=".build/$CONFIG/Peek"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Peek"

# 应用图标：缺了就用 tools/make_icon.swift 现画一个
if [ ! -f build/AppIcon.icns ] && [ -f tools/make_icon.swift ]; then
  bash tools/make_icns.sh build/AppIcon.icns
fi
if [ -f build/AppIcon.icns ]; then
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# 构建标识：把这次的提交和构建时间写进包，用来确认装上去的到底是哪一版。
# 上一轮排查「改了代码但行为没变」时，就是靠翻时间戳和字符串才判断出二进制没更新，
# 有了这两个字段，「关于」页和启动日志一眼就能看出来。
BUILD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
if git rev-parse --git-dir >/dev/null 2>&1; then
  git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null || BUILD_COMMIT="${BUILD_COMMIT}+"
fi
BUILD_TIME=$(date "+%Y-%m-%d %H:%M")

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Peek</string>
    <key>CFBundleIdentifier</key>
    <string>com.peek.translator</string>
    <key>CFBundleName</key>
    <string>Peek</string>
    <key>CFBundleDisplayName</key>
    <string>Peek</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.7</string>
    <key>CFBundleVersion</key>
    <string>8</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Add :PeekBuildCommit string $BUILD_COMMIT" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PeekBuildTime string $BUILD_TIME" "$APP/Contents/Info.plist" 2>/dev/null || true
echo "构建标识: $BUILD_COMMIT ($BUILD_TIME)"
# 签名：优先用本地自签名身份（tools/signing），退化到 ad-hoc。
#
# 为什么要自签名而不是 ad-hoc：
#   辅助功能这类 TCC 授权是绑在代码签名上的。ad-hoc 签名没有证书，
#   系统只能拿 cdhash 认人 —— 每次改代码重编 cdhash 就变，之前
#   在系统设置里勾的 Peek 就"看着勾着、实际失效"。
#   换成固定证书后 DR 变成 "identifier + certificate leaf = H`hash`"，
#   只跟证书走，重编多少次授权都还在。
#
# 没有证书的话先跑 tools/signing/make_cert.sh 生成一个（见 README「签名」）。
SIGN_ID="${PEEK_SIGN_ID:-Peek Local Signing}"
SIGN_KC="${PEEK_SIGN_KC:-$HOME/Library/Keychains/peek-signing.keychain-db}"
SIGN_KC_PASS="${PEEK_SIGN_KC_PASS:-peek}"
BUNDLE_ID="com.peek.translator"

if security find-key "$SIGN_ID" -g "$SIGN_KC" >/dev/null 2>&1 \
   || security find-identity "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
  security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KC" 2>/dev/null || true
  codesign --force --keychain "$SIGN_KC" --sign "$SIGN_ID" \
    --identifier "$BUNDLE_ID" "$APP" 2>/dev/null \
    && echo "签名: ${SIGN_ID}（授权可跨重编保留）" \
    || { echo "签名: 自签失败，回退 ad-hoc"; \
         codesign --force --sign - --identifier "$BUNDLE_ID" \
           --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP" 2>/dev/null; }
else
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP" 2>/dev/null
  echo "签名: ad-hoc（重编后需重新授权辅助功能）"
fi

echo "built: $(pwd)/$APP"
echo "大小: $(du -sh "$APP" | cut -f1)  二进制: $(du -h "$APP/Contents/MacOS/Peek" | cut -f1)"
