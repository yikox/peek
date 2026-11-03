#!/bin/bash
# 一键安装：构建 → 装到 /Applications → 重新签名 → 注册 → 重启
# 用法: ./install.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")"

DEST="/Applications/Peek.app"
CONFIG="${1:-release}"

echo "==> 构建 ($CONFIG)"
./build.sh "$CONFIG"

echo "==> 停止旧实例"
pkill -x Peek 2>/dev/null || true
sleep 0.5

echo "==> 安装到 $DEST"
rm -rf "$DEST"
# 用 ditto 而不是 cp -R：保留扩展属性/资源分叉，签名不容易被破坏
ditto dist/Peek.app "$DEST"
xattr -cr "$DEST"

echo "==> 签名（自签证书优先，保住 TCC 授权）"
SIGN_ID="${PEEK_SIGN_ID:-Peek Local Signing}"
SIGN_KC="${PEEK_SIGN_KC:-$HOME/Library/Keychains/peek-signing.keychain-db}"
SIGN_KC_PASS="${PEEK_SIGN_KC_PASS:-peek}"
BUNDLE_ID="com.peek.translator"
if security find-identity "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
  security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KC" 2>/dev/null || true
  codesign --force --keychain "$SIGN_KC" --sign "$SIGN_ID" \
    --identifier "$BUNDLE_ID" "$DEST"
else
  echo "    （没找到自签证书，用 ad-hoc；重编后需重新授权。想长期有效先跑 tools/signing/make_cert.sh）"
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$DEST"
fi
codesign -d -r- "$DEST" 2>&1 | tail -1

echo "==> 注册到 LaunchServices"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$DEST" || true

echo "==> 启动"
open -a "$DEST"
sleep 1.5

echo "==> 状态"
[ -f "$HOME/Library/Logs/Peek.log" ] && tail -8 "$HOME/Library/Logs/Peek.log" || true
echo "完成: $DEST"
