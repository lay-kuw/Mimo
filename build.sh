#!/bin/bash
# Mimo をビルドする
#   bash build.sh           ビルドだけ（build/Mimo.app）
#   bash build.sh install   ビルドして ~/Applications に入れて起動
#   bash build.sh dmg       ほかの Mac 用の dmg を作る（Apple Silicon と Intel の両対応）
set -euo pipefail
cd "$(dirname "$0")"

NAME="Mimo"
APP="build/$NAME.app"
BIN="$APP/Contents/MacOS/$NAME"
MODE="${1:-}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {   # compile <arch> <出力先>
  swiftc -O -whole-module-optimization -swift-version 5 \
    -target "$1-apple-macos13.0" \
    Sources/*.swift \
    -framework AppKit -framework IOKit -framework CoreText -framework SystemConfiguration \
    -Xlinker -dead_strip \
    -o "$2"
}

echo "✦ compiling..."
if [ "$MODE" = "dmg" ]; then
  # 配る用は Apple Silicon と Intel のどちらでも動くようにする
  SLICES="$(mktemp -d)"
  compile arm64 "$SLICES/arm64"
  compile x86_64 "$SLICES/x86_64"
  lipo -create "$SLICES/arm64" "$SLICES/x86_64" -output "$BIN"
  rm -rf "$SLICES"
else
  # 手元で使う分は、この Mac 用だけ（そのぶん軽い）
  compile "$(uname -m)" "$BIN"
fi
strip -x "$BIN"   # デバッグ用の情報を削って小さく

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Skins "$APP/Contents/Resources/Skins"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# アイコン：小さく作ってある Resources/AppIcon.icns を使う。
# AppIcon.png のほうが新しければ、そこから .icns を作り直す
if [ -s Resources/AppIcon.icns ] && [ ! Resources/AppIcon.png -nt Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  WORK="$(mktemp -d)"
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$WORK"
fi

# 強化ランタイム（--options runtime）付きで署名：ほかのプログラムがこのアプリにコードを差し込むのを防ぐ
# 失敗したら隠さずに止める（署名できていないアプリを入れないように）
if ! codesign --force --options runtime --sign - "$APP" 2>/dev/null; then
  echo "✗ 署名に失敗しました（codesign）" >&2
  exit 1
fi

# セルフテスト：計算や操作の確認。1つでも失敗したら、入れる前に止める
if ! RESULT="$("$BIN" --selftest 2>&1)"; then
  echo "$RESULT" >&2
  echo "✗ セルフテストに失敗しました" >&2
  exit 1
fi
echo "✦ $(echo "$RESULT" | tail -1)"
echo "✦ できた: $APP ($(du -sh "$APP" | cut -f1))"

case "$MODE" in
  install)
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x "$NAME" || true
    sleep 0.5
    rm -rf "$DEST/$NAME.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/$NAME.app"
    echo "✦ $DEST に入れて起動しました"
    ;;
  dmg)
    DMG="build/$NAME $VERSION.dmg"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    # 開いたら、アプリを Applications（/Applications）にドラッグするだけ。
    # どの Mac にもある /Applications を指すので、作った Mac のユーザ名は dmg に入らない
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "✦ dmg: $DMG ($(du -sh "$DMG" | cut -f1))"
    ;;
esac
