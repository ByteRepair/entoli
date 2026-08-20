#!/usr/bin/env bash
# Fetches what tool/bundle/build.sh needs but does not build itself: the Hexagon
# SDK, which is the whole of the NPU backend. It lands in
# tool/bundle/toolchains/, which is gitignored, and build.sh looks for it there
# on its own — so this is one command with nothing to copy out of it.
#
#   tool/android-setup.sh
#   ANDROID_NDK_ROOT=$HOME/.android/ndk/<version> tool/bundle/build.sh arm64-v8a
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/bundle/versions.sh"

# The only prebuilt Qualcomm publishes for Linux is x86_64.
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] ||
  { echo "the Hexagon SDK build here is Linux x86_64 only" >&2; exit 1; }

sdk=$here/bundle/toolchains/hexagon/$HEXAGON_SDK_VERSION
if [ -d "$sdk" ]; then
  echo "==> Hexagon SDK $HEXAGON_SDK_VERSION already unpacked"
  exit 0
fi

archive=$here/bundle/toolchains/hexagon-sdk-$HEXAGON_SDK_VERSION.tar.xz
mkdir -p "$here/bundle/toolchains/hexagon"

if [ ! -f "$archive" ]; then
  echo "==> fetching Hexagon SDK $HEXAGON_SDK_VERSION (about 660 MiB)"
  # curl's meter redraws with \r, which off a terminal is thousands of lines
  # rather than one that updates.
  if [ -t 2 ]; then meter=--progress-bar; else meter=--no-progress-meter; fi
  curl -fL --retry 3 "$meter" -o "$archive.part" "$HEXAGON_SDK_URL"
  mv "$archive.part" "$archive"
fi

echo "==> checking it"
if [ -z "$HEXAGON_SDK_SHA256" ]; then
  # Nothing publishes a checksum for this archive, so bumping the version means
  # computing one here and pinning what you get.
  echo "no HEXAGON_SDK_SHA256 in versions.sh; this is" >&2
  sha256sum "$archive" >&2
  exit 1
fi
echo "$HEXAGON_SDK_SHA256  $archive" | sha256sum -c -

echo "==> unpacking"
tar -C "$here/bundle/toolchains/hexagon" -xf "$archive"
[ -d "$sdk" ] || { echo "no $HEXAGON_SDK_VERSION/ inside the archive" >&2; exit 1; }
