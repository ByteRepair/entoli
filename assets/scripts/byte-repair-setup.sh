#!/bin/sh
# Byte Repair setup: installs make, github-cli, and ESBMC so they are on PATH
# for every agent turn in the project. Runs inside the configured terminal env
# (proot rootfs on Android, host shell on desktop), so uname -m picks the arch
# the binary actually runs on.
#
# Both install decisions belong to the caller, not to this script:
# - ENV_INSTALL_DIR: where to install. Refused when unset.
# - ENV_PACKAGE_MANAGER: what installs packages there (apk on Alpine). Unset
#   means the host, whose package manager is not ours to touch; anything the
#   script then needs is fetched as a static binary instead.
set -e

if [ -z "$ENV_INSTALL_DIR" ]; then
  echo "ENV_INSTALL_DIR is not set. The installation directory must be set explicitly; nothing was installed." >&2
  exit 1
fi

BIN="$ENV_INSTALL_DIR"
mkdir -p "$BIN"

have() {
  command -v "$1" >/dev/null 2>&1
}

# Best-effort install of a tool through the provided package manager. $1 is
# the tool's binary name; the package name it maps to is settled here, since
# apk and pacman call gh github-cli and the rest call it gh.
#
# Where no manager was provided this is a skip, not a failure: the host's
# package manager is not ours to reach for. Where one was provided and it
# fails, the failure propagates — a guest install that did not happen must
# not read as done.
try_install() {
  case "$1:$ENV_PACKAGE_MANAGER" in
    make:*)            pkg=make ;;
    gh:apk|gh:pacman)  pkg=github-cli ;;
    gh:*)              pkg=gh ;;
    *)                 pkg="$1" ;;
  esac
  case "$ENV_PACKAGE_MANAGER" in
    "")
      echo "No package manager was provided; skipping: $1" >&2
      ;;
    apk)
      apk add --no-cache "$pkg"
      ;;
    apt-get)
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
      ;;
    dnf)
      dnf install -y "$pkg"
      ;;
    yum)
      yum install -y "$pkg"
      ;;
    pacman)
      pacman -Sy --noconfirm "$pkg"
      ;;
    *)
      echo "Unknown package manager: $ENV_PACKAGE_MANAGER" >&2
      return 1
      ;;
  esac
}

# --- make and github-cli ------------------------------------------------------
have make || try_install make
have gh || try_install gh

# --- ESBMC --------------------------------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   ASSET="esbmc-linux.zip" ;;
  aarch64|arm64)  ASSET="esbmc-linux-armv8.zip" ;;
  *)
    echo "unsupported architecture for ESBMC: $ARCH" >&2
    exit 1
    ;;
esac

if ! have esbmc; then
  URL="https://github.com/esbmc/esbmc/releases/latest/download/$ASSET"
  TMPZIP="/tmp/_esbmc.zip"

  if have wget; then
    wget -q -O "$TMPZIP" "$URL"
  elif have curl; then
    curl -fsSL -o "$TMPZIP" "$URL"
  else
    echo "neither wget nor curl is available" >&2
    exit 1
  fi

  # Extract the whole archive, since the layout varies between releases
  # (v8.4: bin/esbmc at root; v8.5: release/bin/esbmc).
  TMPDIR_EXTRACT="/tmp/_esbmc_extract"
  mkdir -p "$TMPDIR_EXTRACT"

  if have unzip; then
    unzip -o "$TMPZIP" -d "$TMPDIR_EXTRACT"
  elif have python3; then
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

  mv "$ESBMC_BIN" "$BIN/esbmc"
  rm -rf "$TMPDIR_EXTRACT" "$TMPZIP"
fi

# Skipped installs leave no file here — esbmc found on PATH is a machine the
# script had nothing to do for — so both of these are the found-binary's own
# business rather than this run's.
chmod +x "$BIN/esbmc" 2>/dev/null || true
"$BIN/esbmc" --version 2>/dev/null || esbmc --version || true