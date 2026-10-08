#!/bin/sh
# Builds a signed, notarized DMG of the macOS app, ready to hand out: the
# Mac counterpart to Apps/Gnome/install.sh.
#
#   Apps/Apple/package.sh            # → Apps/Apple/build/Circles-<version>.dmg
#
# Needs a "Developer ID Application" certificate in the keychain and your
# team ID, from Config/Local.xcconfig (DEVELOPMENT_TEAM) or $TEAM_ID.
#
# Notarization runs when $NOTARY_PROFILE names a notarytool keychain profile.
# Create one once (it asks for an app-specific password from
# account.apple.com):
#
#   xcrun notarytool store-credentials circles-notary --apple-id you@example.com --team-id ABCDE12345
#   NOTARY_PROFILE=circles-notary Apps/Apple/package.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
build="$here/build"
team=${TEAM_ID:-$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "$here/Config/Local.xcconfig" 2>/dev/null || true)}
if [ -z "$team" ]; then
    echo "No team ID: set TEAM_ID, or DEVELOPMENT_TEAM in Config/Local.xcconfig." >&2
    exit 1
fi
identity=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)
if [ -z "$identity" ]; then
    echo "No \"Developer ID Application\" certificate for team $team in the keychain." >&2
    exit 1
fi

rm -rf "$build"
mkdir -p "$build"

echo "==> Archiving (Release, $identity)"
xcodebuild -project "$here/Circles.xcodeproj" -scheme Circles -configuration Release \
    -archivePath "$build/Circles.xcarchive" -derivedDataPath "$build/DerivedData" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
    archive -quiet

app="$build/Circles.xcarchive/Products/Applications/Circles.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

echo "==> Checking the signature"
codesign --verify --deep --strict --verbose=1 "$app"
codesign -dvv "$app" 2>&1 | grep -E "^(Authority=Developer ID Application|TeamIdentifier|Timestamp|Runtime Version)"
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow"; then
    echo "The app has the get-task-allow entitlement; notarization would reject it." >&2
    exit 1
fi

echo "==> Building the disk image"
staging="$build/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
dmg="$build/Circles-$version.dmg"
hdiutil create -quiet -volname "Circles $version" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
rm -rf "$staging"
codesign --sign "$identity" --timestamp "$dmg"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
    echo "==> Done: $dmg (signed, notarized and stapled)"
else
    echo "==> Done: $dmg (signed, not notarized)"
    echo "    Gatekeeper will block it on other Macs until it's notarized: set NOTARY_PROFILE (see the top of this script)."
fi
