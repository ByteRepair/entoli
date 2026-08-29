#!/bin/sh
# Byte Repair setup: installs make, github-cli, and ESBMC into the target bin
# directory. Runs inside the configured terminal env (proot rootfs on Android,
# host shell on desktop), so uname -m picks the arch the binary actually runs on.
#
# Usage: sh byte-repair-setup.sh <bindir>
set -e

BINDIR="$1"
if [ -z "$BINDIR" ]; then
  echo "usage: $0 <bindir>" >&2
  exit 1
fi
mkdir -p "$BINDIR"

# --- make and github-cli -----------------------------------------------------
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache make github-cli
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y make gh
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y make gh
elif command -v yum >/dev/null 2>&1; then
  yum install -y make gh
elif command -v pacman >/dev/null 2>&1; then
  pacman -Sy --noconfirm make github-cli
else
  echo "no known package manager; skipping make and github-cli" >&2
fi

# --- ESBMC -------------------------------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   ASSET="esbmc-linux.zip" ;;
  aarch64|arm64)  ASSET="esbmc-linux-armv8.zip" ;;
  *)
    echo "unsupported architecture for ESBMC: $ARCH" >&2
    exit 1
    ;;
esac

URL="https://github.com/esbmc/esbmc/releases/latest/download/$ASSET"
TMPZIP="$BINDIR/_esbmc.zip"

if command -v wget >/dev/null 2>&1; then
  wget -q -O "$TMPZIP" "$URL"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$TMPZIP" "$URL"
else
  echo "neither wget nor curl is available" >&2
  exit 1
fi

# Extract bin/esbmc into BINDIR.
if command -v unzip >/dev/null 2>&1; then
  unzip -o "$TMPZIP" "bin/esbmc" -d "$BINDIR"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c "
import zipfile, os, shutil
z = zipfile.ZipFile('$TMPZIP')
z.extract('bin/esbmc', '$BINDIR')
shutil.move(os.path.join('$BINDIR','bin','esbmc'), os.path.join('$BINDIR','esbmc'))
os.rmdir(os.path.join('$BINDIR','bin'))
"
elif command -v busybox >/dev/null 2>&1 && busybox unzip >/dev/null 2>&1; then
  busybox unzip -o "$TMPZIP" "bin/esbmc" -d "$BINDIR"
else
  echo "no unzip tool available (unzip, python3, busybox)" >&2
  rm -f "$TMPZIP"
  exit 1
fi

# The zip extracts to bin/esbmc; flatten it to <bindir>/esbmc.
if [ -f "$BINDIR/bin/esbmc" ]; then
  mv "$BINDIR/bin/esbmc" "$BINDIR/esbmc"
  rmdir "$BINDIR/bin" 2>/dev/null || true
fi

chmod +x "$BINDIR/esbmc"
rm -f "$TMPZIP"

echo "ESBMC installed to $BINDIR/esbmc"
"$BINDIR/esbmc" --version || true