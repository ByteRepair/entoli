#!/usr/bin/env bash
# Put built tools where the APK packages them from.
#
#   tool/android/stage.sh [source]
#
# `source` defaults to tool/android/dist and holds one directory per ABI.
# Anything already in jniLibs for an ABI is replaced, so a stale build cannot
# ride along.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
src=${1:-$here/dist}
dest=$root/android/app/src/main/jniLibs

if [ ! -d "$src" ]; then
  echo "nothing to stage: $src does not exist" >&2
  exit 1
fi

staged=0
for dir in "$src"/*/; do
  abi=$(basename "$dir")
  case "$abi" in
    arm64-v8a|armeabi-v7a|x86_64) ;;
    *) continue ;;
  esac
  shopt -s nullglob
  libs=("$dir"*.so)
  shopt -u nullglob
  [ ${#libs[@]} -gt 0 ] || continue
  rm -rf "${dest:?}/$abi"
  mkdir -p "$dest/$abi"
  cp "${libs[@]}" "$dest/$abi/"
  echo "staged $abi: $(basename -a "${libs[@]}" | tr '\n' ' ')"
  staged=$((staged + 1))
done

if [ "$staged" -eq 0 ]; then
  echo "nothing to stage: no ABI directories under $src" >&2
  exit 1
fi
