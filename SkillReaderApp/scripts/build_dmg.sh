#!/bin/bash
# build_dmg.sh — 打包 SkillReader-<版本>.dmg（含拖拽安装窗口）
# 用法：./build_dmg.sh   版本号取环境变量 APP_VERSION（默认 1.0）
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAME="SkillReader"
VERSION="${APP_VERSION:-1.0}"
STAGING="$(mktemp -d)"
BUILD_DIR="$PROJECT_DIR/build"
DMG="$BUILD_DIR/$NAME-$VERSION.dmg"
trap 'rm -rf "$STAGING"' EXIT

echo "━━ 1/3 构建 .app 到临时目录 ━━"
"$PROJECT_DIR/scripts/build_app.sh" "$STAGING/$NAME.app"
echo "  ✓ $NAME.app"

echo "━━ 2/3 组装拖拽安装布局 ━━"
ln -s /Applications "$STAGING/Applications"

echo "━━ 3/3 生成 .dmg ━━"
mkdir -p "$BUILD_DIR"
rm -f "$DMG"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" | sed 's/^/  /'
test -f "$DMG" || { echo "✗ dmg 生成失败"; exit 1; }

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo ""
echo "✓ 已生成：$DMG ($SIZE)"
