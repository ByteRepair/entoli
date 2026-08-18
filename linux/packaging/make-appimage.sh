#!/usr/bin/env bash
# Packages a `flutter build linux` bundle as an AppImage, e.g.
#   linux/packaging/make-appimage.sh build/linux/x64/release/bundle dist/entoli.AppImage
set -euo pipefail

bundle="${1:?usage: make-appimage.sh <bundle-dir> <output.AppImage>}"
output="${2:?usage: make-appimage.sh <bundle-dir> <output.AppImage>}"

here="$(dirname "$(readlink -f "$0")")"
root="$(cd "$here/../.." && pwd)"
desktop="$here/io.github.yiannis128.agent_chat.desktop"
# The name the icon has to take, read from the entry that decides it.
icon="$(sed -n 's/^Icon=//p' "$desktop")"

appimagetool=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
# Pinned and checked: this builds the file a release is attested by, and a
# release tag can be moved.
appimagetool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
appdir="$work/AppDir"

# The bundle goes in whole and unrearranged: the launcher resolves lib/ through
# an $ORIGIN/lib rpath and finds data/ beside itself, so anything lifted out of
# it is a file the app cannot open.
mkdir -p "$appdir/usr/bin"
cp -r "$bundle/." "$appdir/usr/bin/"

install -m755 "$here/AppRun" "$appdir/AppRun"
install -Dm644 "$desktop" "$appdir/usr/share/applications/$(basename "$desktop")"
# The PWA set is the default icon already rendered; see "The app icon".
install -Dm644 "$root/web/icons/Icon-512.png" \
  "$appdir/usr/share/icons/hicolor/512x512/apps/$icon.png"

# appimagetool reads both from the AppDir root, a desktop installs them from
# usr/share, and a link is one file in the image rather than two.
ln -s "usr/share/applications/$(basename "$desktop")" "$appdir/"
ln -s "usr/share/icons/hicolor/512x512/apps/$icon.png" "$appdir/"

curl -fsSL -o "$work/appimagetool" "$appimagetool"
sha256sum -c - <<<"$appimagetool_sha  $work/appimagetool"
chmod +x "$work/appimagetool"

mkdir -p "$(dirname "$output")"
# appimagetool is itself an AppImage, and a CI runner has no FUSE to mount one
# with.
APPIMAGE_EXTRACT_AND_RUN=1 "$work/appimagetool" "$appdir" "$output"
