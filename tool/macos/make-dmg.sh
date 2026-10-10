#!/usr/bin/env bash
# Packages a `flutter build macos` app as a DMG, e.g.
#   tool/macos/make-dmg.sh build/macos/Build/Products/Release/Entoli.app dist/entoli.dmg
#
# The app is what Flutter built: universal, ad-hoc signed. `--sign` re-signs it
# with a Developer ID under hardened runtime, which is what notarization demands;
# an ad-hoc build skips this and a Finder "right-click, Open" is what runs it on
# another Mac. Notarization is a distribution step rather than a packaging one:
# `xcrun notarytool submit <dmg>`, then `xcrun stapler staple <dmg>`, the image
# being notarizable whole so the ticket travels inside it.
set -euo pipefail

usage="usage: make-dmg.sh <app> <output.dmg> [--sign <identity>]"
app="${1:?"$usage"}"
output="${2:?"$usage"}"
# The name the volume takes, from the entry that decided it: AppInfo.xcconfig.
name="$(basename "$app" .app)"

if [ "${3:-}" = "--sign" ]; then
  identity="${4:?"$usage"}"
  # Hardened runtime without entitlements: the app is unsandboxed and runs
  # commands through dart:io, so the Release entitlements file stays empty
  # while ever it does. --deep re-signs the frameworks Flutter produced
  # ad-hoc (the engine and the plugins) with the same identity.
  codesign --force --deep --options runtime --timestamp \
    --sign "$identity" "$app"
  codesign --verify --strict "$app"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
staging="$work/$name"
mkdir -p "$staging"
# -c clones on APFS and falls back to a copy elsewhere, so the bundle moves
# without being read and written.
cp -c -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

mkdir -p "$(dirname "$output")"
# Where diskutil has the image verb, that is the create hdiutil's is
# deprecated for, and it overwrites by itself. Older macOS keeps hdiutil.
if diskutil image >/dev/null 2>&1; then
  diskutil image create from --format UDZO --volumeName "$name" "$staging" "$output"
else
  hdiutil create -volname "$name" -srcfolder "$staging" -ov -format UDZO "$output"
fi