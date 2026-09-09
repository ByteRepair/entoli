#!/usr/bin/env bash
# Builds llama.cpp's server for the Linux desktop, and stages it where the app
# bundles it from. Shares the pin in tool/android/versions.sh rather than
# carrying a second copy of it.
#
#   tool/linux/build-llama.sh
#
# Output, stripped, in <repo>/build/llama/ (gitignored): the server and the
# shared libraries it loads beside it, sonames and symlinks kept.
# `linux/CMakeLists.txt` installs that directory into the bundle's lib/ when it
# is filled, so a build without this step still builds — the same shape as an
# Android APK built without the bundled tools.
#
# The backends are the CPU and Vulkan, which is what the Android build carries
# minus the NPU: ggml has no desktop NPU story, and Hexagon is Snapdragon's
# DSP. The CUDA and ROCm backends would each want their own SDK and are not
# built here. GGML_BACKEND_DL makes every backend a libggml-*.so loaded at
# runtime, so a machine whose Vulkan driver is absent or too old runs the CPU
# rather than refusing to start.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
source "$here/../android/versions.sh"
source "$root/tool/fetch.sh"

work=${WORK_DIR:-$here/../android/build}
# The directory CMake installs from — the repo root's build/, which flutter
# build writes beside rather than into. `$here/../build` would be tool/build,
# a tree nothing else reads.
out=${OUT_DIR:-$root/build/llama}
jobs=${JOBS:-$(nproc)}

# The host's own compiler, since this is a native build: no toolchain file, and
# nothing here may reach the NDK's.
export CC=${CC:-cc}
export CXX=${CXX:-c++}

mkdir -p "$work"

echo "==> fetching sources"
fetch "$LLAMA_CPP_URL" "llama.tar.gz" "$LLAMA_CPP_SHA256"
fetch "$SPIRV_HEADERS_URL" "spirv-headers.tar.gz" "$SPIRV_HEADERS_SHA256"
fetch "$VULKAN_HEADERS_URL" "vulkan-headers.tar.gz" "$VULKAN_HEADERS_SHA256"

src=$work/linux
mkdir -p "$src"
[ -d "$src/llama.cpp-$LLAMA_CPP_VERSION" ] || tar -C "$src" -xf "$work/llama.tar.gz"

echo "==> llama.cpp $LLAMA_CPP_VERSION"
(
  cd "$src/llama.cpp-$LLAMA_CPP_VERSION"
  bdir=build-linux
  if [ -f "$bdir/llama-server" ]; then
    echo "==> already built, reusing"
  else
    # SPIRV-Headers, which ggml-vulkan's cmake requires at configure time.
    # Installed here, not built — the same arrangement build.sh makes, and for
    # the same reason: `project()` runs a compiler check, and the one compiler
    # that is right for that is the host's own. The stanza is build.sh's
    # lines 156–180 kept in step; its one delta is the compiler that check is
    # allowed to find, this script's being the host's own everywhere.
    spirv_src=$src/SPIRV-Headers-$SPIRV_HEADERS_VERSION
    spirv=$src/spirv-headers-root
    [ -d "$spirv_src" ] || tar -C "$src" -xf "$work/spirv-headers.tar.gz"
    if [ ! -f "$spirv/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" ]; then
      cmake -S "$spirv_src" -B "$spirv_src/build" \
        -DCMAKE_INSTALL_PREFIX="$spirv" -DSPIRV_HEADERS_ENABLE_TESTS=OFF >/dev/null
      cmake --install "$spirv_src/build" >/dev/null
    fi

    # The Vulkan headers, unpacked and pointed at — the `include/` below is
    # `-DVulkan_INCLUDE_DIR`. ggml-vulkan.cpp also includes `spirv/…`, which it
    # expects to sit beside `vulkan/` the way a real Vulkan SDK lays them out
    # rather than reaching it through the SPIRV-Headers target it never links.
    # The Vulkan-Headers tarball has no `spirv/`, so the one from SPIRV-Headers
    # above is merged in to give that include dir the SDK's shape.
    vulkan_headers=$src/Vulkan-Headers-$VULKAN_HEADERS_VERSION
    [ -d "$vulkan_headers" ] || tar -C "$src" -xf "$work/vulkan-headers.tar.gz"
    [ -d "$vulkan_headers/include/spirv" ] ||
      cp -r "$spirv_src/include/spirv" "$vulkan_headers/include/spirv"

    # glslc, which compiles the backend's shaders at build time. The Android
    # build reaches into the NDK's shader-tools for it; a native build takes
    # the host's own (Fedora: glslc; Debian and Ubuntu: glslc in universe).
    glslc=$(command -v glslc || true)
    [ -n "$glslc" ] ||
      { echo "no glslc on PATH (a distro package ships it)" >&2; exit 1; }

    # The loader, which the backend links and the machine's driver stack
    # provides. The headers are pointed at the pinned ones below — the same
    # ones the Android build compiles against, so the two builds see the same
    # API — but the loader is the system's own, as it is on any desktop: the
    # ICDs it finds at runtime are the machine's drivers, and a stale
    # bundled loader is a backend that finds none of them. Where the stack is
    # not installed, -DGGML_VULKAN=OFF is the honest build. Found through
    # ldconfig rather than `find_package`, whose FindVulkan wants an SDK
    # layout nothing here needs.
    vulkan_lib=$(ldconfig -p | awk '/libvulkan\.so\.1/{print $NF; exit}')
    [ -n "$vulkan_lib" ] ||
      { echo "no libvulkan.so.1 (package: vulkan-loader)" >&2; exit 1; }
    echo "==> Vulkan loader: $vulkan_lib"

    # A native build wants no toolchain file, and one flag carries the weight
    # the ANDROID_ABI one does on the other side.
    #
    # `GGML_NATIVE=OFF` is load-bearing for a distributed binary: it leaves
    # ggml's runtime dispatch on, so one binary runs a 2015 x-86-64 and a
    # Zen 5 both. `native` would bake this machine's -march into it.
    # `GGML_BACKEND_DL`, `GGML_OPENMP` and `LLAMA_CURL` are shared with the
    # Android build and said there. `LLAMA_OPENSSL=OFF` pins what that build
    # got by accident: the option defaults ON, the app does its own
    # downloading, and where the host has libssl3's dev files — the CI
    # runner, any desktop that does — it would link libssl.so.3 into what is
    # staged, which the check below refuses.
    cmake -B "$bdir" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_SKIP_BUILD_RPATH=ON \
      -DGGML_BACKEND_DL=ON \
      -DGGML_NATIVE=OFF \
      -DGGML_OPENMP=OFF \
      -DGGML_VULKAN=ON \
      -DVulkan_INCLUDE_DIR="$vulkan_headers/include" \
      -DVulkan_LIBRARY="$vulkan_lib" \
      -DVulkan_GLSLC_EXECUTABLE="$glslc" \
      -DSPIRV-Headers_DIR="$spirv/share/cmake/SPIRV-Headers" \
      -DLLAMA_CURL=OFF \
      -DLLAMA_OPENSSL=OFF \
      -DLLAMA_BUILD_SERVER=ON \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_APP=OFF \
      -DLLAMA_BUILD_UI=OFF
    cmake --build "$bdir" -j"$jobs" --target llama-server >/dev/null
  fi

  # Built shared and found through `LD_LIBRARY_PATH` — the arrangement
  # `LlamaBinaries.environment` already makes — so the staging copies the
  # bin/ directory's libraries whole: the server and every libllama-*/libggml*
  # it names, symlinks preserved, since `NEEDED` carries the soname and a
  # flattened copy of the real files only is a loader that cannot resolve it.
  # The build tree's rpath points back here, and is stripped from what leaves.
  rm -rf "$out"
  mkdir -p "$out"
  cp -P "$bdir"/bin/lib*.so* "$out/"
  cp "$bdir/bin/llama-server" "$out/"
  # One pass over the real files, in the shape build.sh's strip loop is: the
  # soname symlinks beside them are names of the same ELF, and walking them
  # would read each library once per name it answers to.
  real_files=$(find "$out" -type f \( -name "lib*.so.*" -o -name llama-server \))
  echo "$real_files" | xargs strip
  # CMake puts a runpath naming this build tree into what it links; a staged
  # binary must resolve by name out of `LD_LIBRARY_PATH` or nothing else.
  while IFS= read -r lib; do
    [ -f "$lib" ] || continue
    rpath=$(patchelf --print-rpath "$lib" 2>/dev/null || true)
    case "$rpath" in *"$bdir"*) patchelf --remove-rpath "$lib" ;; esac
  done <<<"$real_files"
  # A build with no rpath left resolves by name, so every `NEEDED` has to be
  # beside it — the same check build.sh makes against the NDK sysroot, minus
  # the sysroot half: the libc-family names are the machine's to provide.
  echo "==> checking what is staged"
  unlinkable=0
  while IFS= read -r lib; do
    while IFS= read -r need; do
      [ -f "$out/$need" ] || {
        case "$need" in
          # The loader and libc family: everywhere a desktop Linux is, and
          # libvulkan with them — the loader is the machine's driver stack,
          # found at runtime rather than shipped (see above).
          ld-linux*|libc.so*|libm.so*|libgcc*|libstdc++*|libdl*|libpthread*|librt*|libvulkan*) ;;
          *) echo "  ${lib##*/} needs $need, which is not staged" >&2; unlinkable=1 ;;
        esac
      }
    done < <(readelf -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
  done <<<"$real_files"
  [ "$unlinkable" = 0 ] || exit 1
)

echo "==> staged $out"
( cd "$out" && ls -l )