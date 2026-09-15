#!/usr/bin/env bash
# Packages and codegen: everything a checkout needs before anything compiles.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

flutter pub get
# The fetched skills the bundled presets are completed with; before the
# generator that walks them.
tool/fetch-skills.sh
dart run tool/gen_bundled_skills.dart
dart run tool/gen_prompts.dart
dart run tool/gen_privacy_policy.dart
dart run build_runner build

# `version.json` is a declared asset; About reads it on platforms whose
# build tool does not write its own.
version="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)"
printf '{"version":"%s"}\n' "$version" > assets/version.json
