#!/bin/sh
# Puts the model host inside the app: Contents/Helpers/Entoli Models.app, a
# background-only bundle of its own around a copy of the Runner's executable.
# Run by the Runner target's last build phase, so it sees the build's
# variables and the executable the link step just wrote. See "The model host"
# in macos/AGENTS.md.
#
# A copy rather than a second target: the host runs the code the app runs —
# `modelHostMain` through the same engine, the same `MlxChannel` — and a
# target of its own would be a second list of sources to keep in step. What
# differs is the bundle around it: its own identifier, no Dock icon, and an
# rpath to the app's Frameworks, where the engine, EntoliMLX and the Dart code
# already are.
set -eu

app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
helper="$app/Contents/Helpers/Entoli Models.app"
executable="Entoli Models"

rm -rf "$helper"
mkdir -p "$helper/Contents/MacOS"

cp "$app/Contents/MacOS/$EXECUTABLE_NAME" "$helper/Contents/MacOS/$executable"
# @executable_path is the helper's own MacOS directory, four levels inside the
# app's Contents.
install_name_tool -add_rpath "@executable_path/../../../../Frameworks" \
  "$helper/Contents/MacOS/$executable"
# No nib: `AppDelegate.main` starts the host on `entoli-models` before AppKit
# would load one, so the bundle carries no window to load.

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")"
cat > "$helper/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$executable</string>
	<key>CFBundleIdentifier</key>
	<string>$PRODUCT_BUNDLE_IDENTIFIER.models</string>
	<key>CFBundleName</key>
	<string>$executable</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$build</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MACOSX_DEPLOYMENT_TARGET</string>
	<key>LSBackgroundOnly</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

# Signed before the app's own signature is made over it, which seals it as
# nested code. The build's identity and entitlements, so a debug build's JIT
# entitlement reaches the host too; the DMG re-signs both for a release.
set -- --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ]; then
  set -- "$@" --options runtime
fi
if [ -n "${CODE_SIGN_ENTITLEMENTS:-}" ]; then
  set -- "$@" --entitlements "$PROJECT_DIR/$CODE_SIGN_ENTITLEMENTS"
fi
codesign "$@" "$helper"
