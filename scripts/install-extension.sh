#!/bin/sh
# Builds the Xcode Source Editor Extension and installs its host app into ~/Applications.
#
#   scripts/install-extension.sh
#
# Then: System Settings → General → Login Items & Extensions → Xcode Source Editor → turn on
# "SwiftUI Stability", restart Xcode, and use Editor → SwiftUI Stability. Re-run to update.
# Signed to run locally (no developer team needed). To remove: delete ~/Applications/SwiftUI Stability.app.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d)
DEST="$HOME/Applications"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# macOS registers every built app, so the build copy would show up as a second extension in System Settings:
# unregister it and delete the build folder, whatever happens.
cleanup() {
    BUILT="$BUILD/Build/Products/Release/SwiftUI Stability.app"
    if [ -d "$BUILT" ]; then
        pluginkit -r "$BUILT/Contents/PlugIns/SwiftUIStabilityExtension.appex" 2>/dev/null || true
        "$LSREGISTER" -u "$BUILT" 2>/dev/null || true
    fi
    rm -rf "$BUILD"
}
trap cleanup EXIT

echo "Building the extension (Release)…"
xcodebuild -project "$ROOT/EditorExtension/SwiftUIStability.xcodeproj" -scheme SwiftUIStability \
    -configuration Release -derivedDataPath "$BUILD" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build >"$BUILD/build.log" 2>&1 \
    || { tail -20 "$BUILD/build.log"; exit 1; }

mkdir -p "$DEST"
rm -rf "$DEST/SwiftUI Stability.app"
cp -R "$BUILD/Build/Products/Release/SwiftUI Stability.app" "$DEST/"
# Launching the host app once registers the extension with macOS.
open "$DEST/SwiftUI Stability.app"
echo "Installed $DEST/SwiftUI Stability.app"
echo "Next: System Settings → General → Login Items & Extensions → Xcode Source Editor → turn on SwiftUI Stability, then restart Xcode."
