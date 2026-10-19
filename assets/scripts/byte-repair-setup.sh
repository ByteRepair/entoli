# Byte Repair setup: installs make, github-cli, and ESBMC so they are on PATH
# for every agent turn in the project. Runs inside the configured terminal env
# (proot rootfs on Android, host shell on the desktops), so uname -s picks the
# platform the binary must be a release of, and uname -m its word size where
# the release splits by that.
#
# The install decisions belong to the caller, not to this script:
# - ENV_INSTALL_DIR: where to install. Refused when unset.
# - ENV_PACKAGE_MANAGER: what installs packages there (apk on Alpine, brew on
#   a mac). Unset means a host whose package manager is not ours to touch;
#   anything the script then needs is fetched as a static binary instead.
#   brew is the one that installs outside ENV_INSTALL_DIR: what it installs
#   lives in Homebrew's own prefix and is linked into ENV_INSTALL_DIR.
# - ENV_BREW: the brew executable, with ENV_PACKAGE_MANAGER=brew. Unset means
#   Homebrew is not installed.
# - ENV_ESBMC_BINARY: the name the release's binary carries — esbmc, or the
#   .exe anything Windows runs needs the extension to exec. Unset means the
#   POSIX name.
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

# Works, not just present: a present-but-unstartable binary once read as
# installed, was skipped, and setup exited 0 having done nothing.
works() {
  "$1" --version >/dev/null 2>&1
}

# Homebrew is the mac's whole answer: the ESBMC release for macOS is linked
# against Homebrew's z3, mpfr, gmp, boost and llvm by absolute path and
# carries none of them, so a fetched zip cannot start where those kegs are
# missing. Homebrew itself is not installed here: its installer wants sudo,
# which a setup with no terminal cannot answer, so its absence is a refusal
# naming the command, which the settings page shows too.
if [ "$ENV_PACKAGE_MANAGER" = brew ]; then
  BREW="$ENV_BREW"
  if [ -z "$BREW" ] || [ ! -x "$BREW" ]; then
    echo "Homebrew is not installed, and setup installs make, GitHub CLI and ESBMC with it. Install it by pasting this into a terminal, then run setup again:" >&2
    echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
    exit 1
  fi
  BREW_PREFIX=$("$BREW" --prefix)
  export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 NONINTERACTIVE=1
fi

# A tool Homebrew holds, linked rather than copied into $BIN: a brew upgrade
# moves what the binary loads, and a copy would be left pointing at the old
# kegs where a link follows the formula.
link_brew() {
  ln -sf "$2" "$BIN/$1"
}

# --- make and github-cli ------------------------------------------------------
# One invocation, not one per tool: apk --no-cache re-fetches the package
# index on every call, and a phone pays that twice otherwise.
PKGS=""
works make || PKGS="make"
works gh || PKGS="$PKGS gh"
if [ -n "$PKGS" ]; then
  # The mapping is the script's, not the call site's: apk and pacman call gh
  # github-cli and the rest call it gh.
  case "$ENV_PACKAGE_MANAGER" in
    apk)     PKGS=" ${PKGS%% gh} github-cli" ;;
    apt-get|dnf|yum|pacman|brew|"") ;;
    *)       echo "Unknown package manager: $ENV_PACKAGE_MANAGER" >&2; exit 1 ;;
  esac
  case "$ENV_PACKAGE_MANAGER" in
    "")
      echo "No package manager was provided; skipping: $PKGS" >&2
      ;;
    apk)
      apk update && apk upgrade
      apk add --no-cache $PKGS
      ;;
    apt-get)
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS
      ;;
    dnf)
      dnf install -y $PKGS
      ;;
    yum)
      yum install -y $PKGS
      ;;
    pacman)
      pacman -Sy --noconfirm $PKGS
      ;;
    brew)
      "$BREW" install $PKGS
      # Homebrew's make is gmake on PATH; the make name is in gnubin.
      for pkg in $PKGS; do
        case "$pkg" in
          make) link_brew make "$BREW_PREFIX/opt/make/libexec/gnubin/make" ;;
          gh)   link_brew gh "$BREW_PREFIX/bin/gh" ;;
        esac
      done
      ;;
  esac
fi

# --- ESBMC --------------------------------------------------------------------
# Homebrew's formula where brew is the package manager. Otherwise the release
# zip, whose asset follows the platform the script runs on, not the word size alone:
# uname -s names the OS, and a guest's zip is not a desktop's — a mac picking
# the linux one by its arm was the state before there was one of its own. The
# binary's name is the caller's, not probed: the gate asking for the file the
# setup lands and the import writing under it ask the same const.
BINARY="${ENV_ESBMC_BINARY:-esbmc}"
if [ "$ENV_PACKAGE_MANAGER" = brew ]; then
  # What the bin directory already links to is kept when it runs; anything
  # else there — a link to a removed keg, the unstartable zip binary an
  # older setup left — goes, so the PATH probe below cannot find it.
  if ! works "$BIN/$BINARY"; then
    rm -f "$BIN/$BINARY"
    if works "$BINARY"; then
      ESBMC_SRC=$(command -v "$BINARY")
    else
      "$BREW" install esbmc
      ESBMC_SRC="$BREW_PREFIX/bin/$BINARY"
    fi
    link_brew "$BINARY" "$ESBMC_SRC"
  fi
else
  OS=$(uname -s)
  case "$OS" in
    Darwin)
      ASSET="esbmc-macos.zip"
      ;;
    Linux)
      case "$(uname -m)" in
        aarch64|arm64) ASSET="esbmc-linux-armv8.zip" ;;
        *)             ASSET="esbmc-linux.zip" ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      ASSET="esbmc-windows.zip"
      ;;
    *)
      echo "unsupported platform for ESBMC: $OS" >&2
      exit 1
      ;;
  esac

  if ! works "$BINARY"; then
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
    # Found is not running here either — works, not have: Windows' Store
    # python3 stub is on every default install's PATH and dies when run, and
    # set -e would end the setup before a real answer below it is reached.
    elif works python3; then
      python3 -c "
import zipfile
z = zipfile.ZipFile('$TMPZIP')
z.extractall('$TMPDIR_EXTRACT')
"
    elif command -v busybox >/dev/null 2>&1 && busybox unzip >/dev/null 2>&1; then
      busybox unzip -o "$TMPZIP" -d "$TMPDIR_EXTRACT"
    elif have cygpath && have powershell.exe; then
      # Git-for-Windows' bash ships no unzip; PowerShell's Expand-Archive is a
      # call away, and cygpath is what turns the MSYS paths into arguments it
      # reads.
      powershell.exe -NoProfile -Command "Expand-Archive -Force -Path \"$(cygpath -w $TMPZIP)\" -DestinationPath \"$(cygpath -w $TMPDIR_EXTRACT)\"" >/dev/null
    else
      echo "no unzip tool available (unzip, python3, busybox, powershell)" >&2
      rm -f "$TMPZIP"
      exit 1
    fi

    ESBMC_BIN=$(find "$TMPDIR_EXTRACT" -name "$BINARY" -type f | head -1)
    if [ -z "$ESBMC_BIN" ]; then
      echo "esbmc binary not found in archive" >&2
      rm -rf "$TMPDIR_EXTRACT" "$TMPZIP"
      exit 1
    fi

    # The binary's own directory moves whole, not the binary alone: a release's
    # bin/ carries what loads the binary with it (the windows release's
    # libz3.dll), and one file taken out of its company is the one that cannot
    # start afterwards. Nothing from the levels above — README, licenses,
    # headers — follows.
    ESBMC_BIN_DIR=$(dirname "$ESBMC_BIN")
    mv -f "$ESBMC_BIN_DIR"/* "$BIN/"
    chmod +x "$BIN/$BINARY"
    rm -rf "$TMPDIR_EXTRACT" "$TMPZIP"
  else
    # Nothing is fetched: the machine's own binary is the one running, but
    # what the turns find and the gate asks for afterwards is what $BIN
    # holds — so it is copied in. The re-setup run that would copy the file
    # onto itself is the [ -f ]'s answer.
    if [ ! -f "$BIN/$BINARY" ]; then
      cp "$(command -v "$BINARY")" "$BIN/$BINARY"
      chmod +x "$BIN/$BINARY"
    fi
  fi
fi

# The binary that stands at the end is the one the turns will run: what the
# two arms above leave in $BIN, fetched or copied in. It is verified outright
# rather than falling back to whatever PATH answers — a bin directory holding
# an unstartable leftover while a machine binary works behind it would be the
# gate, the turns and the setup's own exit reading three different things.
if ! "$BIN/$BINARY" --version 2>&1; then
  echo "the esbmc at $BIN/$BINARY cannot be run (see the error above); setup did not succeed" >&2
  exit 1
fi