#!/bin/bash
# Полный релизный пайплайн: build → sign (Developer ID) → notarize → DMG → staple.
# Перед первым запуском один раз:
#   xcrun notarytool store-credentials "notch-agents-notary" \
#     --key <путь к AuthKey_*.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Aleksei Koledachkin (TQ5423H59B)"
PROFILE="notch-agents-notary"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
APP="build/NotchAgents.app"
ZIP="build/NotchAgents-$VERSION.zip"
DMG="build/NotchAgents-$VERSION.dmg"

echo "→ release build (v$VERSION)"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchAgents "$APP/Contents/MacOS/"
cp scripts/Info.plist "$APP/Contents/Info.plist"

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

echo "→ codesign: Developer ID + hardened runtime"
codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "→ notarize app (может занять пару минут)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "→ build DMG"
STAGE="build/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Notch Agents" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "→ sign + notarize DMG"
codesign --force --timestamp -s "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "→ gatekeeper check"
spctl -a -t open --context context:primary-signature -v "$DMG" && echo "✓ DMG accepted by Gatekeeper"
echo ""
echo "✓ готово к раздаче: $DMG"
