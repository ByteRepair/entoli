# Byte Repair setup: installs make, github-cli and ESBMC so they are on PATH
# for every agent turn in the project. The caller decides, the script obeys:
# - ENV_INSTALL_DIR: where the tools land. Required.
# - ENV_PACKAGE_MANAGER: apk in a guest, brew on a mac, unset on a host whose
#   package manager is not ours to touch (missing tools are then skipped, and
#   ESBMC is fetched from its release).
# - ENV_BREW: the brew executable, with ENV_PACKAGE_MANAGER=brew.
# - ENV_ESBMC_BINARY: the binary's file name, esbmc.exe on Windows. Default esbmc.
# See "Byte Repair's environment, in four variables" in lib/data/local/AGENTS.md.
set -eu

BIN="${ENV_INSTALL_DIR:-}"
PM="${ENV_PACKAGE_MANAGER:-}"
BINARY="${ENV_ESBMC_BINARY:-esbmc}"

fail() {
  echo "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# Runs, not just present: a found but unstartable binary must not read as
# installed.
works() {
  "$1" --version >/dev/null 2>&1
}

[ -n "$BIN" ] || fail "ENV_INSTALL_DIR is not set. The installation directory must be set explicitly; nothing was installed."
case "$PM" in
  ""|apk|brew) ;;
  *) fail "Unknown package manager: $PM" ;;
esac
mkdir -p "$BIN"

# Homebrew is not installed here: its installer asks for sudo, which a run
# with no terminal cannot answer. The settings page shows the same command.
if [ "$PM" = brew ]; then
  BREW="${ENV_BREW:-}"
  if [ -z "$BREW" ] || [ ! -x "$BREW" ]; then
    echo "Homebrew is not installed, and setup installs make, GitHub CLI and ESBMC with it. Install it by pasting this into a terminal, then run setup again:" >&2
    fail '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  fi
  BREW_PREFIX=$("$BREW" --prefix)
  # Install what is missing and touch nothing else: no upgrading a formula
  # the user already has, or the formulae that depend on what was upgraded,
  # and no cleanup of the old versions their own builds may still link.
  export HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
fi

# Linked, not copied: a brew upgrade moves the libraries a copy would still
# point at, where a link follows the formula.
link_tool() {
  case "$2" in
    /*) ;;
    *) fail "cannot link $1 to the relative path $2" ;;
  esac
  ln -sf "$2" "$BIN/$1"
  works "$BIN/$1" || fail "$1 was installed, but $BIN/$1 does not run; setup did not succeed"
}

# --- make and github-cli ------------------------------------------------------
missing=""
works make || missing="make"
works gh || missing="${missing:+$missing }gh"
if [ -n "$missing" ]; then
  case "$PM" in
    "")
      echo "No package manager was provided; skipping: $missing" >&2
      ;;
    apk)
      # One call for both: --no-cache fetches the index on every call. gh is
      # github-cli on Alpine.
      pkgs=""
      for tool in $missing; do
        case "$tool" in
          gh) pkgs="$pkgs github-cli" ;;
          *)  pkgs="$pkgs $tool" ;;
        esac
      done
      apk add --no-cache $pkgs || fail "apk could not install:$pkgs"
      ;;
    brew)
      "$BREW" install $missing || fail "brew could not install: $missing"
      for tool in $missing; do
        case "$tool" in
          # Homebrew's make is gmake on PATH; the make name is in gnubin.
          make) link_tool make "$BREW_PREFIX/opt/make/libexec/gnubin/make" ;;
          gh)   link_tool gh "$BREW_PREFIX/bin/gh" ;;
        esac
      done
      ;;
  esac
fi

# --- ESBMC --------------------------------------------------------------------
# Whatever ends up in $BIN is what the gate and the turns use, so a working
# binary found elsewhere on PATH is linked or copied in, not left where it is.

install_esbmc_brew() {
  works "$BIN/$BINARY" && return 0
  # A link to a removed keg, or the unstartable zip binary an older setup
  # left: gone first, so the PATH probe below cannot find it.
  rm -f "$BIN/$BINARY"
  if works "$BINARY"; then
    link_tool "$BINARY" "$(command -v "$BINARY")"
  else
    "$BREW" install esbmc || fail "brew could not install esbmc"
    link_tool "$BINARY" "$BREW_PREFIX/bin/$BINARY"
  fi
}

esbmc_asset() {
  case "$(uname -s)" in
    # The mac release links Homebrew's z3, mpfr, gmp, boost and llvm by
    # absolute path and ships none of them: it only starts where brew would.
    Darwin) fail "ESBMC's macOS release needs Homebrew's libraries; run setup with ENV_PACKAGE_MANAGER=brew" ;;
    Linux)
      case "$(uname -m)" in
        x86_64|amd64)  echo "esbmc-linux.zip" ;;
        aarch64|arm64) echo "esbmc-linux-armv8.zip" ;;
        *) fail "ESBMC has no Linux release for $(uname -m)" ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*) echo "esbmc-windows.zip" ;;
    *) fail "unsupported platform for ESBMC: $(uname -s)" ;;
  esac
}

download() {
  if have wget; then
    wget -q -T 30 -O "$2" "$1"
  elif have curl; then
    curl -fsSL --connect-timeout 30 --retry 2 -o "$2" "$1"
  else
    fail "neither wget nor curl is available to download ESBMC"
  fi || fail "could not download $1"
}

extract() {
  if have unzip; then
    unzip -q -o "$1" -d "$2"
  # works, not have: Windows' Store python3 stub is on PATH and dies when run.
  elif works python3; then
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
  elif have cygpath && have powershell.exe; then
    # Git for Windows' bash has no unzip. Single-quoted for PowerShell, with
    # a quote in a path doubled.
    zip=$(cygpath -w "$1" | sed "s/'/''/g")
    dest=$(cygpath -w "$2" | sed "s/'/''/g")
    powershell.exe -NoProfile -Command "Expand-Archive -Force -LiteralPath '$zip' -DestinationPath '$dest'" >/dev/null
  else
    fail "no unzip tool available (unzip, python3 or PowerShell)"
  fi || fail "could not extract the ESBMC archive"
}

install_esbmc_release() {
  if works "$BINARY"; then
    # The re-run that would copy $BIN's own binary onto itself is the -f's.
    if [ ! -f "$BIN/$BINARY" ]; then
      cp "$(command -v "$BINARY")" "$BIN/$BINARY"
      chmod +x "$BIN/$BINARY"
    fi
    return 0
  fi

  asset=$(esbmc_asset)
  # Scratch beside $BIN rather than in a shared /tmp: a fresh name, no other
  # user's files, the final mv a rename, and gone however the run ends. A
  # run killed outright leaves its scratch to the next one to sweep.
  rm -rf "$BIN"/.esbmc-download.*
  scratch=$(mktemp -d "$BIN/.esbmc-download.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  trap 'exit 1' HUP INT TERM

  download "https://github.com/esbmc/esbmc/releases/latest/download/$asset" "$scratch/esbmc.zip"
  extract "$scratch/esbmc.zip" "$scratch/x"

  # Under a bin/ wherever the release puts it (v8.4: bin/, v8.5: release/bin/).
  found=$(find "$scratch/x" -path "*/bin/$BINARY" -type f | head -1)
  [ -n "$found" ] || fail "esbmc binary not found in $asset"
  # The whole bin/, not the binary alone: it carries what loads the binary
  # (the windows release's libz3.dll).
  mv -f "$(dirname "$found")"/* "$BIN/"
  chmod +x "$BIN/$BINARY"
}

if [ "$PM" = brew ]; then
  install_esbmc_brew
else
  install_esbmc_release
fi

# $BIN's binary itself, not whatever PATH answers: it is what the gate and
# the turns will run.
"$BIN/$BINARY" --version 2>&1 ||
  fail "the esbmc at $BIN/$BINARY cannot be run (see the error above); setup did not succeed"
