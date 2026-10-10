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

app="${1:?usage: make-dmg.sh <Entoli.app> <output.dmg> [--sign identity]}"
output="${2:?usage: make-dmg.sh <Entoli.app> <output.dmg> [--sign identity]}"

if [ "${3:-}" = "--sign" ]; then
  identity="${4:?usage: make-dmg.sh <app> <dmg> [--sign "Developer ID Application: name"]}"
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
staging="$work/Entoli"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

output_dir="$(dirname "$output")"
mkdir -p "$output_dir"
rm -f "$output"
hdiutil create -volname Entoli -srcfolder "$staging" -ov -format UDZO "$output"