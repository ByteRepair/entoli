#!/usr/bin/env bash
# Everything a checkout needs before it will analyze, test, run or build.
#
# The generated sources are not in the repository — `*.g.dart` and
# `*.freezed.dart` are `.gitignore`d — so this has to run once after a clone
# and again whenever a `@freezed` or `@JsonSerializable` type changes. It is
# idempotent and cheap when nothing moved, so re-running it is never wrong.
#
# Unlike `android-setup.sh`, which only a build targeting the NPU needs, this
# one is needed for *anything*: without it nothing compiles and an editor
# shows an error on every file that has a `part` directive.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter pub get
dart run build_runner build --delete-conflicting-outputs
