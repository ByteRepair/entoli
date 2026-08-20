#!/usr/bin/env bash
# Fetches what tool/bundle/build.sh needs but does not build itself: the Hexagon
# SDK, which is the whole of the NPU backend. Everything lands in
# tool/bundle/toolchains/, which is gitignored.
#
#   tool/android-setup.sh
#   HEXAGON_SDK_ROOT=<what it prints> tool/bundle/build.sh arm64-v8a
#
# Under GitHub Actions it appends HEXAGON_SDK_ROOT to $GITHUB_ENV instead, so a
# later step builds with the NPU without repeating the path.
#
# Safe to re-run: an SDK already unpacked is left alone.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
source "$root/tool/bundle/versions.sh"

# The only prebuilt Qualcomm publishes for Linux is x86_64, and the toolchain
# inside is host code — an arm64 box cannot run it under anything here.
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] ||
  { echo "the Hexagon SDK build here is Linux x86_64 only" >&2; exit 1; }

toolchains=$root/tool/bundle/toolchains
sdk=$toolchains/hexagon/$HEXAGON_SDK_VERSION

if [ -d "$sdk" ]; then
  echo "==> Hexagon SDK $HEXAGON_SDK_VERSION already unpacked"
else
  archive=$toolchains/hexagon-sdk-$HEXAGON_SDK_VERSION.tar.xz
  mkdir -p "$toolchains/hexagon"

  if [ ! -f "$archive" ]; then
    echo "==> fetching Hexagon SDK $HEXAGON_SDK_VERSION (about 660 MiB)"
    # curl's meter redraws with \r, which off a terminal — a CI log — becomes
    # thousands of lines rather than one that updates.
    if [ -t 2 ]; then meter=--progress-bar; else meter=--no-progress-meter; fi
    curl -fL --retry 3 "$meter" -o "$archive.part" "$HEXAGON_SDK_URL"
    mv "$archive.part" "$archive"
  fi

  echo "==> checking it"
  actual=$(sha256sum "$archive" | cut -d' ' -f1)
  if [ -z "$HEXAGON_SDK_SHA256" ]; then
    # Nobody signs this archive, so the pin in versions.sh is the only thing
    # standing between a compromised mirror and a compiler that runs here and
    # emits what ships in the APK. Refusing beats unpacking it unchecked.
    echo "HEXAGON_SDK_SHA256 is unset in tool/bundle/versions.sh." >&2
    echo "What downloaded is:" >&2
    echo "  $actual" >&2
    echo "Pin that only if you trust where it came from." >&2
    exit 1
  fi
  if [ "$actual" != "$HEXAGON_SDK_SHA256" ]; then
    echo "sha256 mismatch on $archive" >&2
    echo "  expected $HEXAGON_SDK_SHA256" >&2
    echo "  got      $actual" >&2
    exit 1
  fi

  echo "==> unpacking"
  tar -C "$toolchains/hexagon" -xf "$archive"
  [ -d "$sdk" ] ||
    { echo "no $HEXAGON_SDK_VERSION/ inside the archive" >&2; exit 1; }
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "HEXAGON_SDK_ROOT=$sdk" >> "$GITHUB_ENV"
  echo "==> HEXAGON_SDK_ROOT exported for the steps after this one"
else
  echo
  echo "  export HEXAGON_SDK_ROOT=$sdk"
fi
