#!/usr/bin/env bash
#
# 生成「未签名 IPA」，用于全能签 / Sideloadly / AltStore 等第三方签名平台自签。
#
# 用法：
#   ./build_ipa.sh
#   BUNDLE_ID=com.yourname.navnative ./build_ipa.sh
#
# 产物：build/NavNative-unsigned.ipa
#
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="NavNative"
PROJECT="NavNative.xcodeproj"
CONFIG="Release"
OUT_DIR="build"
ARCHIVE_PATH="$OUT_DIR/NavNative.xcarchive"
IPA_NAME="NavNative-unsigned.ipa"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "错误：未找到 xcodebuild。iOS 应用必须在 macOS + Xcode 上编译。" >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> [1/4] 编译（完全关闭代码签名）"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ${BUNDLE_ID:+PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"} \
    clean archive \
    | tail -n 30

APP_PATH="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "错误：未找到编译产物：$APP_PATH" >&2
    exit 1
fi

echo "==> [2/4] 清除签名残留"
rm -rf "$APP_PATH/_CodeSignature"
rm -f  "$APP_PATH/embedded.mobileprovision"
find "$APP_PATH" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP_PATH" -name "embedded.mobileprovision" -delete 2>/dev/null || true
/usr/bin/codesign --remove-signature "$APP_PATH" >/dev/null 2>&1 || true

if /usr/bin/codesign -dv "$APP_PATH" >/dev/null 2>&1; then
    echo "警告：仍检测到签名，若签名失败请手动检查" >&2
else
    echo "    已确认：无签名"
fi

echo "==> [3/4] 校验产物"
if [ ! -f "$APP_PATH/NavNative" ]; then
    echo "错误：主二进制缺失" >&2
    exit 1
fi
echo "    主二进制：$(du -h "$APP_PATH/NavNative" | cut -f1)"
echo "    Bundle ID：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || echo unknown)"

echo "==> [4/4] 打包为 IPA（Payload/ 结构）"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP_PATH" "$OUT_DIR/Payload/"
(cd "$OUT_DIR" && /usr/bin/zip -qry "$IPA_NAME" Payload)

echo "==> 完成"
IPA_PATH="$OUT_DIR/$IPA_NAME"
ls -lh "$IPA_PATH" | awk '{print "    文件: " $9 "\n    大小: " $5}'

echo ""
echo "把这个 IPA 直接拖进全能签即可签名安装。"
