#!/usr/bin/env bash
# Fetches the skills the presets are completed with: the latest release of
# ByteRepair/skills, the fork the wording fixes are made in, extracted to
# build/skills-upstream/ for tool/gen_bundled_skills.dart to walk. Run by
# tool/prepare.sh.
#
# The cache is keyed on the release tag, not on a pin: the repo is ours, a
# new release flows in on the next run and nothing here has to be edited.
# A cache hit needs no network; a miss with the network down fails, saying
# so — a half-fetched tree is worse than a loud stop.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

repo="ByteRepair/skills"
work=build/skills-upstream

# The human latest-release URL is a redirect to /tag/<name>; following it
# reads the tag off where it landed. One request, no API JSON, no rate
# limit to trip.
tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/$repo/releases/latest" |
    sed -n 's|.*/tag/||p')"
if [ -z "$tag" ]; then
  echo "fetch-skills: could not resolve the latest release tag" >&2
  exit 1
fi

if [ -f "$work/.tag" ] && [ "$(cat "$work/.tag")" = "$tag" ] &&
    [ -d "$work/skills" ]; then
  echo "fetch-skills: $tag already fetched."
  exit 0
fi

mkdir -p "$work"
rm -rf "$work.tmp"
mkdir -p "$work.tmp"
archive="$work.tmp/skills.tar.gz"
# fetch() checksums what it keeps; there is no pin here to check against,
# so the tarball is a .part until GitHub's TLS has said it is whole.
if ! curl -fsSL --retry 3 -o "$archive" \
    "https://github.com/$repo/archive/refs/tags/$tag.tar.gz"; then
  rm -rf "$work.tmp"
  if [ -d "$work/skills" ]; then
    echo "fetch-skills: could not fetch $tag, keeping the $(cat "$work/.tag") tree already here." >&2
    exit 0
  fi
  echo "fetch-skills: could not fetch $tag and nothing is cached." >&2
  exit 1
fi
tar -xzf "$archive" -C "$work.tmp" --strip-components 1
rm "$archive"

rm -rf "$work"
mv "$work.tmp" "$work"
printf '%s\n' "$tag" > "$work/.tag"
echo "fetch-skills: fetched $tag ($(find "$work/skills" -mindepth 1 -maxdepth 1 -type d | wc -l) skills)."