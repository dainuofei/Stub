#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Stub.xcodeproj"
SCHEME="${SCHEME:-Stub}"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
IPA_PATH="$OUTPUT_DIR/${SCHEME}.ipa"
SIGNING_MODE="${SIGNING_MODE:-unsigned}"

if [[ ! -d "$PROJECT" ]]; then
    echo "找不到工程：$PROJECT" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$IPA_PATH"

if [[ "$SIGNING_MODE" == "auto" ]]; then
    ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/${SCHEME}.xcarchive}"
    EXPORT_DIR="${EXPORT_DIR:-$OUTPUT_DIR/.exported}"
    rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
    mkdir -p "$EXPORT_DIR"

    echo "==> 使用 Xcode 自动签名并归档"
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk iphoneos \
        -archivePath "$ARCHIVE_PATH" \
        archive \
        CODE_SIGN_STYLE=Automatic \
        ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"}

    xcodebuild \
        -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$ROOT_DIR/scripts/ExportOptions.plist" \
        -exportPath "$EXPORT_DIR"

    EXPORTED_IPA="$EXPORT_DIR/${SCHEME}.ipa"
    if [[ ! -f "$EXPORTED_IPA" ]]; then
        echo "Xcode 导出完成，但没有找到：$EXPORTED_IPA" >&2
        exit 1
    fi
    cp "$EXPORTED_IPA" "$IPA_PATH"
else
    if [[ "$SIGNING_MODE" != "unsigned" ]]; then
        echo "SIGNING_MODE 只能是 unsigned 或 auto" >&2
        exit 1
    fi

    DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/build/${SCHEME}-unsigned-derived}"
    rm -rf "$DERIVED_DATA"

    echo "==> 构建未签名 App（由 AltStore 在设备上重新签名）"
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk iphoneos \
        -derivedDataPath "$DERIVED_DATA" \
        build \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO

    APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
    if [[ ! -d "$APP_PATH" ]]; then
        echo "构建完成，但没有找到：$APP_PATH" >&2
        exit 1
    fi

    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stub-ipa.XXXXXX")"
    trap 'rm -rf "$STAGE_DIR"' EXIT
    mkdir -p "$STAGE_DIR/Payload"
    ditto "$APP_PATH" "$STAGE_DIR/Payload/${SCHEME}.app"
    (
        cd "$STAGE_DIR"
        ditto -c -k --sequesterRsrc --keepParent Payload "$IPA_PATH"
    )
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "没有生成 IPA：$IPA_PATH" >&2
    exit 1
fi

echo ""
echo "IPA 已生成：$IPA_PATH"
echo "导入 AltStore：在文件 App 中找到该 IPA，然后选择‘共享’→‘AltStore’。"
