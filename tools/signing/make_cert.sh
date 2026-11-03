#!/bin/bash
# 生成一套本地代码签名证书，并导入独立钥匙串。
#
# 为什么需要它：辅助功能 / 屏幕录制这类 TCC 授权绑在代码签名上。
# ad-hoc 签名没有证书，系统只能拿 cdhash 认人，重编译一次授权就失效。
# 固定证书后 DR = "identifier + certificate leaf = H'…'"，授权一次长期有效。
#
# 用法: ./tools/signing/make_cert.sh
# 产物: tools/signing/{key.pem,cert.pem,identity.p12}  ← 都是私钥材料，已在 .gitignore
#       ~/Library/Keychains/peek-signing.keychain-db
set -euo pipefail
cd "$(dirname "$0")"

CN="${PEEK_SIGN_ID:-Peek Local Signing}"
KC="${PEEK_SIGN_KC:-$HOME/Library/Keychains/peek-signing.keychain-db}"
PASS="${PEEK_SIGN_KC_PASS:-peek}"

if security find-identity "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "已存在: $CN（$KC）"
  exit 0
fi

echo "==> 生成自签证书 $CN"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# openssl 3 默认用 AES-256-CBC + SHA256 做 p12，macOS 的 security 只认老的 RC2/3DES，
# 必须 -legacy -macalg sha1，否则导入报 "MAC verification failed"
openssl pkcs12 -export -legacy -macalg sha1 \
  -out identity.p12 -inkey key.pem -in cert.pem -passout "pass:$PASS" 2>/dev/null

echo "==> 导入钥匙串 $KC"
security create-keychain -p "$PASS" "$KC" 2>/dev/null || true
security unlock-keychain -p "$PASS" "$KC"
security import identity.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign -A
# 允许 codesign 在没有 GUI 授权弹窗的情况下使用这把私钥
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null 2>&1 || true

echo "==> 完成"
security find-identity -v -p codesigning "$KC" | tail -2
echo
echo "私钥材料不要提交：tools/signing/{key.pem,cert.pem,identity.p12} 已在 .gitignore"
