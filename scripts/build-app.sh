#!/bin/bash
# Сборка NotchAgents.app и установка в ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ release build"
swift build -c release

APP="build/NotchAgents.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchAgents "$APP/Contents/MacOS/"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# иконка (рендерится один раз, потом кешируется в build/)
if [ ! -f build/AppIcon.icns ]; then
    echo "→ rendering icon"
    swift scripts/make-icon.swift build/icon-1024.png
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"

echo "→ codesign (ad-hoc)"
codesign --force -s - "$APP"

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/NotchAgents.app"
cp -R "$APP" "$DEST/"
echo "✓ installed: $DEST/NotchAgents.app"
