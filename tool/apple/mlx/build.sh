#!/usr/bin/env bash
# Builds EntoliMLX — mlx-swift-lm behind the three calls AppleFmChannel.swift
# makes — into the XCFramework both Runners link and embed.
#
#   tool/apple/mlx/build.sh [ios] [simulator] [macos]
#
# Names the slices to build, all three by default: a release job wants the
# one it ships, a local run the simulator's too.
#
# Needs macOS and Xcode 27 (an older SDK fails the build: mlx-swift-lm's
# adapter compiles out with it) with the Metal Toolchain component installed
# (xcodebuild -downloadComponent MetalToolchain). Produces, in dist/:
#   EntoliMLX.xcframework — a dynamic framework per slice, arm64 alone.
#
# Not run by the app build, the way tool/ios/ish/build.sh is not: without it
# neither Runner links. Why it is prebuilt at all is `flutter build ios`, which
# always passes -sdk, and -sdk puts mlx-swift-lm's tokenizer macro on the
# iOS SDK when it has to run on this Mac. See "The MLX models" in
# ios/AGENTS.md.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=${WORK_DIR:-$here/build}
out=${OUT_DIR:-$here/dist}

# destination, products directory, module triple
slice_of() {
  case "$1" in
    ios) echo "generic/platform=iOS|Release-iphoneos|arm64-apple-ios" ;;
    simulator) echo "generic/platform=iOS Simulator|Release-iphonesimulator|arm64-apple-ios-simulator" ;;
    macos) echo "generic/platform=macOS|Release|arm64-apple-macos" ;;
    *) echo "No slice named $1: ios, simulator or macos" >&2; exit 1 ;;
  esac
}
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(ios simulator macos)
slices=()
for name in "${names[@]}"; do slices+=("$(slice_of "$name")"); done

rm -rf "$work/frameworks" "$out/EntoliMLX.xcframework"
mkdir -p "$work/frameworks" "$out"
frameworks=()
for slice in "${slices[@]}"; do
  IFS='|' read -r destination products triple <<<"$slice"
  # The macro is the package's own, pinned exactly in Package.swift and
  # Package.resolved; a runner has nobody to click Trust & Enable.
  (cd "$here" && xcodebuild build -scheme EntoliMLX -configuration Release \
    -destination "$destination" -derivedDataPath "$work/dd" \
    -skipMacroValidation -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS=arm64 SKIP_INSTALL=NO CODE_SIGNING_ALLOWED=NO) >"$work/$triple.log" 2>&1 || {
    grep -E "error:" "$work/$triple.log" | sort -u >&2 || true
    echo "EntoliMLX did not build for $triple; the log is $work/$triple.log" >&2
    exit 1
  }

  built="$work/dd/Build/Products/$products"
  framework="$work/frameworks/$triple/EntoliMLX.framework"
  mkdir -p "$(dirname "$framework")"
  cp -R "$built/PackageFrameworks/EntoliMLX.framework" "$framework"

  # A macOS framework is versioned, an iOS one flat: where the binary, the
  # resources and the kernels sit is all that differs. MLX looks for its
  # kernels beside its own binary before anywhere else — mlx.metallib there,
  # then Resources/ — so they travel inside the framework and the app copies
  # nothing. A flat bundle keeps no Resources directory, which codesign takes
  # for a versioned one.
  if [ -d "$framework/Versions/A" ]; then
    root="$framework/Versions/A"
    resources="$root/Resources"
    kernels="$resources/default.metallib"
    ln -sfn Versions/Current/Modules "$framework/Modules"
  else
    root="$framework"
    resources="$framework"
    kernels="$root/mlx.metallib"
  fi

  # Xcode leaves a package framework's module beside it; the interface is
  # what lets a later compiler read it.
  modules="$root/Modules/EntoliMLX.swiftmodule"
  mkdir -p "$modules"
  cp "$built/EntoliMLX.swiftmodule/$triple".* "$modules/"
  cp "$work/dd/Build/Intermediates.noindex/EntoliMLX.build/$products/EntoliMLX-t.build/Objects-normal/arm64/EntoliMLX.swiftinterface" \
    "$modules/$triple.swiftinterface"

  cp "$(find "$built/mlx-swift_Cmlx.bundle" -name default.metallib)" "$kernels"
  # The other packages' bundles are found by their accessors in the
  # framework's resource directory.
  for bundle in "$built"/*.bundle; do
    [ "$(basename "$bundle")" = mlx-swift_Cmlx.bundle ] && continue
    cp -R "$bundle" "$resources/"
  done

  frameworks+=(-framework "$framework")
done

xcodebuild -create-xcframework "${frameworks[@]}" -output "$out/EntoliMLX.xcframework" >/dev/null
echo "Wrote $out/EntoliMLX.xcframework"
