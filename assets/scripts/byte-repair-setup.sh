#!/bin/sh
# Byte Repair setup: installs make, github-cli, and ESBMC into the guest
# rootfs so they are on PATH for every agent turn in the project. Runs inside
# the configured terminal env (proot rootfs on Android, host shell on desktop),
# so uname -m picks the arch the binary actually runs on.
set -e

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
TMPZIP="/tmp/_esbmc.zip"
ESBMC_DIR="/usr/local/bin"

mkdir -p "$ESBMC_DIR"

if command -v wget >/dev/null 2>&1; then
  wget -q -O "$TMPZIP" "$URL"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$TMPZIP" "$URL"
else
  echo "neither wget nor curl is available" >&2
  exit 1
fi

# Extract the whole archive, since the layout varies between releases
# (v8.4: bin/esbmc at root; v8.5: release/bin/esbmc).
TMPDIR_EXTRACT="/tmp/_esbmc_extract"
mkdir -p "$TMPDIR_EXTRACT"

if command -v unzip >/dev/null 2>&1; then
  unzip -o "$TMPZIP" -d "$TMPDIR_EXTRACT"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c "
import zipfile
z = zipfile.ZipFile('$TMPZIP')
z.extractall('$TMPDIR_EXTRACT')
"
elif command -v busybox >/dev/null 2>&1 && busybox unzip >/dev/null 2>&1; then
  busybox unzip -o "$TMPZIP" -d "$TMPDIR_EXTRACT"
else
  echo "no unzip tool available (unzip, python3, busybox)" >&2
  rm -f "$TMPZIP"
  exit 1
fi

ESBMC_BIN=$(find "$TMPDIR_EXTRACT" -name esbmc -type f | head -1)
if [ -z "$ESBMC_BIN" ]; then
  echo "esbmc binary not found in archive" >&2
  rm -rf "$TMPDIR_EXTRACT" "$TMPZIP"
  exit 1
fi

mv "$ESBMC_BIN" "$ESBMC_DIR/esbmc"
rm -rf "$TMPDIR_EXTRACT" "$TMPZIP"

chmod +x "$ESBMC_DIR/esbmc"

echo "ESBMC installed to $ESBMC_DIR/esbmc"
"$ESBMC_DIR/esbmc" --version || true