# shellcheck shell=bash
# What the build scripts share: the one fetch-and-verify primitive, sourced by
# tool/android/build.sh and tool/linux/build-llama.sh, which are otherwise
# separate for their platforms' sake. A fix to the fetch discipline lands here
# or nowhere.
#
# Callers set $work and source this beside tool/android/versions.sh, which
# they source themselves.

# Fetch [url] into $work/[file] unless it is already there, and verify it
# against [sha] either way — the checksum is the only guard against a
# truncated or corrupted cache tarball reaching a shipped binary, so a cache
# hit pays one read to keep it. $work is the caller's: each script fetches
# into its own tree.
fetch() {
  local url=$1 file=$2 sha=$3
  if [ ! -f "$work/$file" ]; then
    curl -fsSL --retry 3 -o "$work/$file.part" "$url"
    mv "$work/$file.part" "$work/$file"
  fi
  echo "$sha  $work/$file" | sha256sum -c - >/dev/null
}