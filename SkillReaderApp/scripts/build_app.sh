#!/bin/bash
# build_app.sh — 编译 SwiftUI SPM 项目并打成 .app bundle（含 adhoc 签名）
# 用法：./build_app.sh [输出路径]   默认 ~/Applications/SkillReader.app
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAME="SkillReader"
TARGET="${1:-/Applications/$NAME.app}"
APP_VERSION="${APP_VERSION:-1.0}"
BUNDLE_ID="${BUNDLE_ID:-com.hwd.skillreader}"

cd "$PROJECT_DIR"

# 0. 重新生成自包含 render.html（vendor 内联）
echo "━━ 0/6 生成 render.html ━━"
/usr/bin/python3 scripts/build_render.py

echo "━━ 1/6 编译 release ━━"
swift build -c release
BIN="$PROJECT_DIR/.build/release/$NAME"
test -f "$BIN" || { echo "✗ 编译产物未找到: $BIN"; exit 1; }
# SPM 资源 bundle（render.html 内联版）
RES_BUNDLE="$PROJECT_DIR/.build/release/${NAME}_${NAME}.bundle"
if [ -d "$RES_BUNDLE" ]; then
    echo "  ✓ 资源 bundle: $(basename "$RES_BUNDLE")"
else
    # 多平台目录回退
    RES_BUNDLE="$(find "$PROJECT_DIR/.build" -name "${NAME}_${NAME}.bundle" -path "*release*" | head -1)"
    test -n "$RES_BUNDLE" || { echo "✗ 资源 bundle 未找到"; exit 1; }
fi

echo "━━ 2/6 生成 icon ━━"
ICON_DIR="$(mktemp -d)"
ICON_PNG="$PROJECT_DIR/Sources/IconGen/$NAME.png"
if [ -f "$ICON_PNG" ]; then
    cp "$ICON_PNG" "$ICON_DIR/icon_1024.png"
else
    if swift "$PROJECT_DIR/scripts/icon.swift" "$ICON_DIR/icon_1024.png" 2>/dev/null; then
        :
    else
        echo "  ! 无图标源图且 icon.swift 失败，跳过图标"
    fi
fi
if [ -f "$ICON_DIR/icon_1024.png" ]; then
    mkdir -p "$ICON_DIR/icon.iconset"
    for size in 16 32 64 128 256 512 1024; do
        sips -z $size $size "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_${size}x${size}.png" > /dev/null
    done
    sips -z 32 32      "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_16x16@2x.png"     > /dev/null
    sips -z 64 64      "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_32x32@2x.png"     > /dev/null
    sips -z 256 256    "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_128x128@2x.png"   > /dev/null
    sips -z 512 512    "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_256x256@2x.png"   > /dev/null
    sips -z 1024 1024  "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_512x512@2x.png"   > /dev/null
    iconutil -c icns "$ICON_DIR/icon.iconset" -o "$ICON_DIR/$NAME.icns"
fi

echo "━━ 3/6 组装 .app bundle ━━"
rm -rf "$TARGET"
mkdir -p "$TARGET/Contents/MacOS" "$TARGET/Contents/Resources"
cp "$BIN" "$TARGET/Contents/MacOS/$NAME"
chmod +x "$TARGET/Contents/MacOS/$NAME"
# 拷贝资源 bundle（render.html）
cp -R "$RES_BUNDLE" "$TARGET/Contents/Resources/"
# 拷贝 Agent 官方 logo
if [ -d "$PROJECT_DIR/Sources/SkillReader/Resources/logos" ]; then
    cp -R "$PROJECT_DIR/Sources/SkillReader/Resources/logos" "$TARGET/Contents/Resources/"
    echo "  ✓ logos: $(ls "$PROJECT_DIR/Sources/SkillReader/Resources/logos" | wc -l | tr -d ' ') 个"
fi
if [ -f "$ICON_DIR/$NAME.icns" ]; then
    cp "$ICON_DIR/$NAME.icns" "$TARGET/Contents/Resources/$NAME.icns"
fi
rm -rf "$ICON_DIR"

cat > "$TARGET/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIconFile</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST

echo "━━ 4/6 adhoc 签名 ━━"
if codesign --force --sign - --identifier "$BUNDLE_ID" --options runtime "$TARGET" 2>&1 | sed 's/^/  /'; then
    if codesign -dv "$TARGET" 2>&1 | grep -q "Identifier=$BUNDLE_ID"; then
        echo "  ✓ 已签名（identifier=$BUNDLE_ID）"
    else
        echo "  ! 签名标识符不符预期，TCC 授权可能记不住"
    fi
else
    echo "  ! 签名失败 —— app 仍可用，但 TCC 授权会反复弹框"
fi

echo "━━ 5/6 验证 ━━"
test -x "$TARGET/Contents/MacOS/$NAME" && echo "  ✓ 可执行文件就绪"
test -f "$TARGET/Contents/Info.plist" && plutil -lint "$TARGET/Contents/Info.plist" > /dev/null && echo "  ✓ Info.plist 就绪"
test -f "$TARGET/Contents/Resources/${NAME}_${NAME}.bundle/render.html" && echo "  ✓ render.html 就绪"
test -f "$TARGET/Contents/Resources/$NAME.icns" && echo "  ✓ 图标就绪"

echo ""
echo "✓ 已生成：$TARGET"
echo "  启动：open \"$TARGET\"  或 Finder 双击"
