#!/bin/zsh
# Builds this fork's app as "Compositor Fork", separate from the released Compositor:
#   - its own name and bundle identifier, so the two sit side by side and never share settings or a sandbox;
#   - its update feed pointed at the fork's empty appcast with automatic checks off, so it is never offered
#     upstream's release (which would replace it with an app that lacks the fork's features).
# Nothing in upstream's sources or project is edited: the changes are made to the built copy, which is then
# signed for this Mac only.
#
#   Fork/build-app.sh             build into Fork/build/
#   Fork/build-app.sh --install   also copy it to /Applications (replacing an earlier fork build)
set -euo pipefail

ROOT="${0:A:h:h}"
NAME="Compositor Fork"
IDENTIFIER="com.opuniverse.compositor-fork"
FEED="https://raw.githubusercontent.com/kojoopuni/Compositor/main/Fork/appcast.xml"
BUILD="$ROOT/Fork/build"
APP="$BUILD/$NAME.app"

echo "Building…"
xcodebuild -project "$ROOT/Compositor.xcodeproj" -scheme Compositor -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build > "$BUILD.log" 2>&1 || { grep -E "error:" "$BUILD.log" | head -20; echo "Build failed; see $BUILD.log"; exit 1; }

rm -rf "$APP"
cp -R "$BUILD/DerivedData/Build/Products/Release/Compositor.app" "$APP"

PLIST="$APP/Contents/Info.plist"
set_key() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 $3 $2" "$PLIST"; }
set_key CFBundleIdentifier "$IDENTIFIER" string
set_key CFBundleName "$NAME" string
set_key CFBundleDisplayName "$NAME" string
set_key SUFeedURL "$FEED" string
set_key SUEnableAutomaticChecks false bool
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)
set_key CFBundleShortVersionString "$VERSION-fork.$COMMIT" string

# The app's entitlements with this build's identifier filled in where Xcode would have done it.
ENTITLEMENTS="$BUILD/fork.entitlements"
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$IDENTIFIER/g" "$ROOT/Config/Compositor.entitlements" > "$ENTITLEMENTS"

# Inside out: Sparkle's helpers first, then the app with its sandbox entitlements. "-" signs for this Mac only.
find "$APP/Contents/Frameworks" -depth \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -perm +111 -type f \) -print0 2>/dev/null \
  | xargs -0 -n1 codesign --force --sign - --timestamp=none 2>/dev/null || true
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION-fork.$COMMIT)"

if [[ "${1:-}" == "--install" ]]; then
  if pgrep -f "/Applications/$NAME.app/" > /dev/null; then echo "Quit $NAME first, then run this again."; exit 1; fi
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" "/Applications/$NAME.app"
  echo "Installed /Applications/$NAME.app"
fi
