#!/usr/bin/env bash
# 一键切换 SkillReader 的 App 图标（仅本地 /Applications 部署用）
# 用法:
#   ./scripts/switch-icon.sh card      # 卡片造型
#   ./scripts/switch-icon.sh bookmark  # 书签造型
#   ./scripts/switch-icon.sh pure      # 纯色造型
# 说明: compare 是横版对比图，不可作 App 图标，故不支持。
set -e

NAME="$1"
if [ -z "$NAME" ]; then
  echo "用法: $0 <card|bookmark|pure>"
  echo "  compare 为横版对比图，不可作为 App 图标"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/IconGen/icon-$NAME.png"
if [ ! -f "$SRC" ]; then
  echo "找不到图标源: $SRC"
  exit 1
fi

APP=/Applications/SkillReader.app
ICONSET="/tmp/sr_${NAME}.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz               "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png"          >/dev/null
  sips -z $((sz*2)) $((sz*2))   "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png"       >/dev/null
done
ICNS="$(mktemp -d)/SkillReader.icns"
iconutil --convert icns "$ICONSET" -o "$ICNS"

pkill -9 -f SkillReader 2>/dev/null; sleep 0.5
cp -f "$ICNS" "$APP/Contents/Resources/SkillReader.icns"
touch "$APP"
open "$APP"
echo "已切换到图标: $NAME"
