#!/usr/bin/env bash
# Packages a `flutter build macos` app as a DMG, e.g.
#   tool/macos/make-dmg.sh build/macos/Build/Products/Release/Entoli.app dist/entoli.dmg
#
# The app is what Flutter built: arm64, ad-hoc signed. `--sign` re-signs it
# with a Developer ID under hardened runtime, which is what notarization demands,
# and signs the image too; an ad-hoc build skips this, and Gatekeeper then
# refuses it on another Mac until Privacy & Security's Open Anyway is clicked.
# Notarization is a distribution step rather than a packaging one:
# `xcrun notarytool submit <dmg>`, then `xcrun stapler staple <dmg>`, the image
# being notarizable whole so the ticket travels inside it.
#
# The window a user's mount opens with is not styled here: it is Finder's own
# .DS_Store from one styling session on a Mac with Finder (the capture recipe in
# macos/AGENTS.md), committed as dmg-window.dsstore and copied verbatim into
# the volume before it is created. Nothing about the copy is generated or
# measured at package time, and nothing needs a Finder session — CI included.
# It stays on hdiutil rather than macOS 27's `diskutil image`, which fails
# intermittently here with an undocumented "error code 156"; only hdiutil's
# deprecation notice is swallowed.
set -euo pipefail

usage="usage: make-dmg.sh <app> <output.dmg> [--sign <identity>]"
app="${1:?"$usage"}"
output="${2:?"$usage"}"
name="$(basename "$app" .app)"
# The bundle name is the product name the Xcode entry decided: AppInfo.xcconfig.
# The volume carries the app's name plus Installer, so what a user sees mounted
# reads as the thing they are installing rather than the app itself; the staged
# item inside is still "<name>.app".
volname="$name Installer"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

script_dir="$(cd "$(dirname "$0")" && pwd)"

identity=""
if [ "${3:-}" = "--sign" ]; then
  identity="${4:?"$usage"}"
  # Signing comes before the staging copy: the clone is APFS copy-on-write, so
  # a staged-then-signed order leaves the volume holding the unsignatured
  # bytes. Two passes: --deep re-signs the frameworks Flutter produced ad-hoc
  # (the engine and the plugins) with the same identity and no entitlements,
  # then the outer bundle alone is signed again with Release.entitlements —
  # passing those to the --deep pass would hand them to every framework too.
  # The force drops whatever the ad-hoc signature carried, so the file is
  # named here rather than inherited from the Xcode build.
  entitlements="$script_dir/../../macos/Runner/Release.entitlements"
  [ -f "$entitlements" ] || { echo "[dmg] $entitlements is missing" >&2; exit 1; }
  codesign --force --deep --options runtime --timestamp \
    --sign "$identity" "$app"
  codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" --sign "$identity" "$app"
  codesign --verify --deep --strict "$app"
fi

# stderr of an hdiutil call — nothing while the call succeeds, everything but
# the deprecation notice when it fails; the exit status is the call's.
hdiutil_run() {
  local err="$work/hdiutil.err" rc=0
  "$@" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    sed "/^hdiutil: WARNING: '/d" "$err" >&2
  fi
  return "$rc"
}

# One line and a failed run, detaching what the flow mounted when it can.
fail() {
  echo "[dmg] $*" >&2
  [ -n "${dev:-}" ] && hdiutil detach "$dev" >/dev/null 2>&1 || true
  exit 1
}

dsstore="$script_dir/dmg-window.dsstore"
background="$script_dir/dmg-background.tiff"
[ -f "$dsstore" ] || fail "the committed window layout (dmg-window.dsstore) is missing"
[ -f "$background" ] || fail "the committed background (dmg-background.tiff) is missing"

staging="$work/staging"
mkdir -p "$staging/.background" "$(dirname "$output")"
cp "$dsstore" "$staging/.DS_Store"
cp "$background" "$staging/.background/background.tiff"
# -c clones on APFS and falls back to a copy elsewhere, so the bundle moves
# without being read and written.
cp -c -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

# The volume takes the app's own icon — found in the bundle rather than named
# here, the .icon package being the authority for that string, as the
# AppImage's script reads the desktop entry for it — and Finder needs the
# custom-bit flag to notice. A missing or unflaggable icon is a line, not a
# failure: the laid-out window still ships.
icon_file=""
for candidate in "$app"/Contents/Resources/*.icns; do
  [ -f "$candidate" ] && icon_file="$candidate"
done
if [ -n "$icon_file" ]; then
  cp "$icon_file" "$staging/.VolumeIcon.icns"
fi

hdiutil_run hdiutil create -volname "$volname" -srcfolder "$staging" \
  -ov -format UDRW "$work/intermediate.dmg" \
  || fail "the image did not create"

if ! attach="$(hdiutil_run hdiutil attach "$work/intermediate.dmg" \
    -readwrite -noverify -nobrowse -noautoopen)"; then
  fail "the image did not attach"
fi
dev="$(printf '%s\n' "$attach" | awk '$1 ~ /^\/dev\/disk/ {print $1; exit}')"
# An APFS image's attach names its mount on a line after the first /dev/disk
# one, so this remembers every line carrying a /Volumes path and emits the
# last — an exit on first match would stop before the mount is ever seen.
mount="$(printf '%s\n' "$attach" | awk \
  '$1 ~ /^\/dev\/disk/ {i = index($0, "/Volumes/"); if (i) m = substr($0, i)} END {print m}')"
mount="${mount%/}"
[ -d "$mount" ] || fail "the attach did not name a mount point"

# The icon flag lives on the volume, not in the committed layout, so it is set
# on the mount of the image that ships; a missing SetFile is a line, the flag
# being what turns the .VolumeIcon.icns into the volume's icon at all.
if [ -n "$icon_file" ]; then
  if ! command -v SetFile >/dev/null 2>&1 || ! SetFile -a C "$mount"; then
    echo "[dmg] the volume icon's custom flag did not set" >&2
  fi
fi

detached=no
for _ in 1 2 3; do
  if hdiutil_run hdiutil detach "$dev"; then detached=yes; break; fi
  sleep 3
done
if [ "$detached" != yes ]; then
  echo "[dmg] detach refused after the flag; forcing it" >&2
  hdiutil_run hdiutil detach "$dev" -force || fail "the volume would not detach"
fi

hdiutil_run hdiutil convert "$work/intermediate.dmg" -format UDZO -ov -o "$output" \
  || fail "the image did not compress for shipping"

# The image is signed as well as the app inside it, so Gatekeeper's check on
# the download itself names the developer; notarization is still the caller's.
if [ -n "$identity" ]; then
  codesign --force --timestamp --sign "$identity" "$output"
  codesign --verify --strict "$output"
fi