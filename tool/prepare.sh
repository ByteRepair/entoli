#!/usr/bin/env bash
# Packages and codegen: everything a checkout needs before anything compiles.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

flutter pub get
# Build_runner before the generators: they import the domain (gen_bundled_skills
# reaches models.dart through skill_validate), whose freezed and json parts do
# not exist until this has run — a cold checkout cannot compile them first.
dart run build_runner build
dart run tool/gen_bundled_skills.dart
dart run tool/gen_prompts.dart
dart run tool/gen_privacy_policy.dart

# `version.json` is a declared asset; About reads it on platforms whose
# build tool does not write its own.
version="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)"
printf '{"version":"%s"}\n' "$version" > assets/version.json
