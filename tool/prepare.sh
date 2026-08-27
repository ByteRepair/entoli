#!/usr/bin/env bash
# Packages and codegen: everything a checkout needs before anything compiles.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

flutter pub get
dart run tool/gen_bundled_skills.dart
dart run build_runner build
