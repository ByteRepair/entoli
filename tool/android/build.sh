#!/usr/bin/env bash
# Builds proot for Android, one ABI at a time, and lays the result out the way
# the app packages it: an executable named lib*.so, because the installer only
# extracts files matching that from an APK, and the native library directory is
# the one place an app is allowed to exec from. See "Bundled tools" in
# AGENTS.md.
#
#   ANDROID_NDK_ROOT=~/.android/ndk/28.2.13676358 tool/android/build.sh arm64-v8a
#
# Output, stripped, in dist/<abi>: libproot.so and its loader
# (libproot-loader.so, plus libproot-loader32.so where the architecture can run
# 32-bit guests), and llama.cpp's server as libllama-server.so with the
# libraries it loads beside it.
#
# The NPU is opt-in, since what it emits is built by Qualcomm's own toolchain.
# `tool/android/setup.sh` fetches the SDK and this picks it up from where that
# put it; HEXAGON_SDK_ROOT overrides for an SDK installed some other way. See
# "Running a model on the device" in AGENTS.md for what it buys and what it
# costs.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/versions.sh"
source "$here/../fetch.sh"

abi=${1:?usage: build.sh <abi>}
work=${WORK_DIR:-$here/build}
out=${OUT_DIR:-$here/dist}/$abi
ndk=${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must point at an NDK}
jobs=${JOBS:-$(nproc)}

# The API level the app itself is built against. Below this the binaries would
# link against symbols a supported device may not have.
api=26

# `triple` names the compiler, `host` the sysroot directory, and for 32-bit arm
# the two disagree.
case "$abi" in
  arm64-v8a)   triple=aarch64-linux-android;    host=aarch64-linux-android ;;
  armeabi-v7a) triple=armv7a-linux-androideabi; host=arm-linux-androideabi ;;
  x86_64)      triple=x86_64-linux-android;     host=x86_64-linux-android ;;
  *) echo "unknown abi: $abi" >&2; exit 2 ;;
esac

toolchain=$ndk/toolchains/llvm/prebuilt/linux-x86_64
bin=$toolchain/bin
# The libraries a device is guaranteed to have, which is what the sysroot holds
# stubs of. Read at the end of the build, to check that nothing links anything
# else.
sysroot=$toolchain/sysroot/usr/lib/$host/$api
export CC=$bin/$triple$api-clang
export AR=$bin/llvm-ar
export STRIP=$bin/llvm-strip
export PATH=$bin:$PATH
# Android 15 wants 16 KB-aligned segments, and a phone that enforces it will not
# load a library built for 4 KB pages.
export CFLAGS="-O2 -fPIC -Wl,-z,max-page-size=16384"

# **llama.cpp is arm64 only, and that is a size decision.** The server and its
# libraries are about 30 MB stripped — nearer 50 with the Vulkan backend, whose
# `libggml-vulkan.so` is 21 MB of embedded SPIR-V on its own — and three
# ABIs of that would be a lot of a universal APK. Nothing is lost: a 32-bit
# phone cannot map a two-gigabyte model at all, and x86_64 Android is an
# emulator. A build without it leaves `LocalLlm.available` false, which the
# settings page says.
llama_abis=${LLAMA_ABIS:-arm64-v8a}
if [[ " $llama_abis " == *" $abi "* ]]; then llama=yes; else llama=no; fi

mkdir -p "$work" "$out"

echo "==> fetching sources"
fetch "$TALLOC_URL" "talloc.tar.gz" "$TALLOC_SHA256"
fetch "$PROOT_URL" "proot.tar.gz" "$PROOT_SHA256"
if [ "$llama" = yes ]; then
  fetch "$LLAMA_CPP_URL" "llama.tar.gz" "$LLAMA_CPP_SHA256"
  fetch "$SPIRV_HEADERS_URL" "spirv-headers.tar.gz" "$SPIRV_HEADERS_SHA256"
  fetch "$VULKAN_HEADERS_URL" "vulkan-headers.tar.gz" "$VULKAN_HEADERS_SHA256"
fi

# Unpacked and built once per ABI. A second run reuses what is there, which is
# what makes iterating on the proot step bearable; CI starts from an empty tree
# either way.
src=$work/$abi
mkdir -p "$src"
[ -d "$src/talloc-$TALLOC_VERSION" ] || tar -C "$src" -xf "$work/talloc.tar.gz"
[ -d "$src/proot-$PROOT_VERSION" ] || tar -C "$src" -xf "$work/proot.tar.gz"
if [ "$llama" = yes ] && [ ! -d "$src/llama.cpp-$LLAMA_CPP_VERSION" ]; then
  tar -C "$src" -xf "$work/llama.tar.gz"
fi

echo "==> talloc $TALLOC_VERSION"
(
  cd "$src/talloc-$TALLOC_VERSION"
  # Inside the versioned tree, so a version bump never links the old archive.
  [ -f libtalloc.a ] && exit 0
  IFS=. read -r major minor release <<<"$TALLOC_VERSION"
  # talloc.c on its own, against the answers in talloc-config.h rather than
  # against waf's — see that file. The version has to be passed in because
  # talloc.c checks the one it was built as against the one in talloc.h.
  $CC -c talloc.c -o talloc.o -I. -Ilib/replace -include "$here/talloc-config.h" \
    -DNO_CONFIG_H -D__STDC_WANT_LIB_EXT1__=1 \
    "-DTALLOC_BUILD_VERSION_MAJOR=$major" \
    "-DTALLOC_BUILD_VERSION_MINOR=$minor" \
    "-DTALLOC_BUILD_VERSION_RELEASE=$release" \
    -O2 -fPIC
  "$AR" rcs libtalloc.a talloc.o
)

echo "==> proot $PROOT_VERSION"
(
  cd "$src/proot-$PROOT_VERSION"
  # Upstream leaves out an include and clang refuses an implicit declaration.
  grep -q "string.h" src/extension/ashmem_memfd/ashmem_memfd.c ||
    sed -i "3i #include <string.h>" src/extension/ashmem_memfd/ashmem_memfd.c
  # --read-only, which keeps -0's faked root from writing where the app made
  # things read-only. Once per tree: a reused tree already has it.
  [ -d src/extension/read_only ] ||
    patch -p1 --quiet < "$here/patches/proot-read-only.patch"
  # Through the environment rather than as make arguments: the makefile appends
  # its own -I, -D_GNU_SOURCE and -ltalloc to all three, and a make argument
  # would replace them instead. Without _GNU_SOURCE proot silently loses
  # process_vm_readv and reads the tracee's memory a word at a time.
  export CC AR STRIP
  export OBJCOPY=$bin/llvm-objcopy OBJDUMP=$bin/llvm-objdump
  export CPPFLAGS="-I$src/talloc-$TALLOC_VERSION -DARG_MAX=131072 -DVERSION=\\\"$PROOT_VERSION\\\""
  export CFLAGS="-O2 -fPIC"
  export LDFLAGS="-L$src/talloc-$TALLOC_VERSION -Wl,-z,max-page-size=16384"
  # Named rather than embedded: an embedded loader is written to a temp file and
  # exec'd, and on Android that file would land where nothing may be executed.
  # The path below is never the one used — the app sets PROOT_LOADER — so it is
  # worded to say what to do if it ever is.
  make -C src -j"$jobs" PROOT_UNBUNDLE_LOADER=/nonexistent-set-PROOT_LOADER proot >/dev/null
  "$STRIP" -o "$out/libproot.so" src/proot
  "$STRIP" -o "$out/libproot-loader.so" src/loader/loader
  # Only where the architecture can run 32-bit guests at all, which is what
  # proot's own arch.h decides.
  if [ -f src/loader/loader-m32 ]; then
    "$STRIP" -o "$out/libproot-loader32.so" src/loader/loader-m32
  fi
)

if [ "$llama" = no ]; then
  echo "==> llama.cpp: not built for $abi"
else
  echo "==> llama.cpp $LLAMA_CPP_VERSION"
  (
    cd "$src/llama.cpp-$LLAMA_CPP_VERSION"
    build=build-$abi
    # cmake seeds CMAKE_C_FLAGS from the environment, and the arm64 linker flag
    # in the CFLAGS this script exports fails the NPU sub-builds' compiler check.
    unset CFLAGS

    # SPIRV-Headers, which ggml-vulkan's cmake requires at configure time.
    # Installed here, not built: it is headers plus a cmake config, and the one
    # thing its `project()` makes cmake do is test a compiler — done with host
    # cc/c++ because the NDK one this script exports would test against Android,
    # which this host-side step is not. `-DSPIRV-Headers_DIR` below points the
    # cross build straight at what this installs.
    spirv_src=$src/SPIRV-Headers-$SPIRV_HEADERS_VERSION
    spirv=$src/spirv-headers-root
    [ -d "$spirv_src" ] || tar -C "$src" -xf "$work/spirv-headers.tar.gz"
    if [ ! -f "$spirv/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" ]; then
      CC=/usr/bin/cc CXX=/usr/bin/c++ cmake -S "$spirv_src" -B "$spirv_src/build" \
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

    # The loader stub the backend links, and it is API 28's, not the 26 the rest
    # of this build uses. ggml-vulkan calls Vulkan 1.1 entry points directly
    # (`vkGetPhysicalDeviceFeatures2` and kin), which Android got in 9.0 — the 26
    # stub does not export them and the link fails. The 28 stub resolves them;
    # the built library still only NEEDs the device's own `libvulkan.so`, so on
    # an API 26 or 27 phone — where that library lacks the symbols —
    # `libggml-vulkan.so` fails to load and GGML_BACKEND_DL drops it to the CPU,
    # which is the honest outcome, there being no Vulkan 1.1 there to offload to.
    vulkan_lib=$toolchain/sysroot/usr/lib/$host/28/libvulkan.so
    # Everything about this build is the NDK's own toolchain file, which is what
    # makes it the one step here with no adjustments to the source at all.
    #
    # `GGML_BACKEND_DL` is the load-bearing option: it makes each backend a
    # `libggml-*.so` loaded at runtime from the directory the binary is in, so an
    # APK carries whichever ones it was built with and the phone uses whichever
    # of those find hardware. Without it the set of backends is fixed at link
    # time, and a build with the NPU in it would refuse to start on a phone that
    # has none.
    #
    # `-DCMAKE_SKIP_INSTALL_RPATH` because the app sets `LD_LIBRARY_PATH` itself:
    # an rpath baked here would name a directory of this machine's, and the
    # install path on a device is not known until the app is installed.
    cmake_args=(
      -B "$build" -G Ninja
      -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI="$abi"
      -DANDROID_PLATFORM="android-$api"
      -DCMAKE_BUILD_TYPE=Release
      -DBUILD_SHARED_LIBS=ON
      -DGGML_BACKEND_DL=ON
      -DGGML_NATIVE=OFF
      # One `libggml-cpu-android_<variant>.so` per ARM feature set, from
      # baseline armv8.0 to SME, and ggml loads the best the phone has. Without
      # it, ggml appends no `-march` when cross-compiling and every Q4_0 fast
      # path `#if`s itself out — see "Where it lives, and what it costs".
      -DGGML_CPU_ALL_VARIANTS=ON
      -DCMAKE_SKIP_INSTALL_RPATH=ON
      # ggml defaults to OpenMP, and the NDK's `libomp.so` is a host toolchain
      # file rather than something a phone has — a build with it links, ships,
      # and then cannot start. ggml carries its own threadpool for exactly this
      # case, which is what llama.cpp's own Android instructions use.
      -DGGML_OPENMP=OFF
      # The GPU backend, and unlike the NPU's it is not opt-in: everything it
      # needs is in the NDK, so it costs a `libggml-vulkan.so` in the APK and
      # nothing at setup. It is the only accelerator most phones have — Hexagon
      # is Snapdragon alone, and a Pixel, a Galaxy or a MediaTek device reaches
      # its GPU through Vulkan or reaches nothing. `libvulkan.so` is Android's
      # own from API 24, so the built backend links only libraries a phone has.
      #
      # The three paths spell out what `find_package(Vulkan)` would otherwise
      # hunt for and miss under the cross toolchain: the loader and headers live
      # in the NDK sysroot at an API-versioned path CMake does not search, and
      # `glslc` is a host tool the NDK ships off `PATH`. The shader generator
      # that `glslc` feeds is a host build of its own; ggml auto-detects the
      # host compiler for it, and finds the system `gcc`/`g++` because the NDK
      # ships neither name.
      -DGGML_VULKAN=ON
      -DVulkan_INCLUDE_DIR="$vulkan_headers/include"
      -DVulkan_LIBRARY="$vulkan_lib"
      -DVulkan_GLSLC_EXECUTABLE="$ndk/shader-tools/linux-x86_64/glslc"
      -DSPIRV-Headers_DIR="$spirv/share/cmake/SPIRV-Headers"
      # The server downloads models when it is told to; this app does its own
      # downloading, and linking curl here would mean cross-compiling it a second
      # time for a feature nothing reaches. LLAMA_OPENSSL is pinned OFF beside
      # it — the option defaults ON, and the NDK today has no OpenSSL for
      # find_package to find, which is OFF by accident; a future NDK that ships
      # it would link libssl into the APK for the staging check's sysroot
      # half to wave through, and the failure would land on a phone.
      -DLLAMA_CURL=OFF
      -DLLAMA_OPENSSL=OFF
      -DLLAMA_BUILD_SERVER=ON
      -DLLAMA_BUILD_TESTS=OFF
      -DLLAMA_BUILD_EXAMPLES=OFF
      -DLLAMA_BUILD_APP=OFF
      # Nothing here opens the server in a browser, and building it wants a host
      # compiler and a download from HuggingFace — two things a build of this
      # should not need.
      -DLLAMA_BUILD_UI=OFF
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384"
      -DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,max-page-size=16384"
    )
    # Fetched by tool/android/setup.sh, or wherever HEXAGON_SDK_ROOT names. The
    # backend arrives as two more `libggml-*.so` and is found like the CPU's.
    #
    # Naming a path asserts it exists, so a typo in it stops the build; the
    # default is only a place to look, so its absence is a CPU build.
    if [ -n "${HEXAGON_SDK_ROOT:-}" ]; then
      [ -d "$HEXAGON_SDK_ROOT" ] ||
        { echo "HEXAGON_SDK_ROOT is not a directory: $HEXAGON_SDK_ROOT" >&2; exit 1; }
      hexagon=$HEXAGON_SDK_ROOT
    else
      hexagon=$here/toolchains/hexagon/$HEXAGON_SDK_VERSION
    fi
    targets=(llama-server)
    if [ -d "$hexagon" ]; then
      echo "==> NPU: $hexagon"
      # The SDK's own cmake reads PREBUILT_LIB_DIR unconditionally; unset, it
      # fails to configure rather than defaulting.
      cmake_args+=(
        -DGGML_HEXAGON=ON -DHEXAGON_SDK_ROOT="$hexagon"
        -DPREBUILT_LIB_DIR=android_aarch64
      )
      # The DSP halves are ExternalProjects nothing on this side links, so
      # building the server alone leaves a backend that finds no skel to run on.
      targets+=(htp-v73 htp-v75 htp-v79 htp-v81)
    fi
    cmake "${cmake_args[@]}" >/dev/null
    cmake --build "$build" -j"$jobs" --target "${targets[@]}" >/dev/null

    # Named lib*.so because that is all the installer extracts from an APK,
    # which for the executable is also the only way it lands somewhere it may
    # be run from. The libraries keep the names they were linked under — the
    # loader resolves those by name, and renaming one is a server that will not
    # start.
    "$STRIP" -o "$out/libllama-server.so" \
      "$(find "$build" -name llama-server -type f | head -1)"
    while IFS= read -r lib; do
      case "$(basename "$lib")" in
        # The DSP-side half of the Hexagon backend, which is not a CPU library
        # at all: it is QDSP6 code, loaded onto the NPU by fastRPC by name out
        # of ADSP_LIBRARY_PATH, and nothing on this side can strip it.
        libggml-htp-*) cp "$lib" "$out/" ;;
        *) "$STRIP" -o "$out/$(basename "$lib")" "$lib" ;;
      esac
    done < <(
      # A skel's own build directory holds the same library it installs beside
      # the backend, and ship/ is SDK prebuilts nothing here links.
      find "$build" -name "lib*.so" -type f \
        -not -path '*-prefix/*' -not -path '*/ship/*'
    )
  )
fi

# The NDK links against libraries a device does not have, and nothing says so
# until the phone refuses to start the binary. So every library named by
# anything staged here has to be either beside it in the APK or Android's to
# provide.
echo "==> checking $abi against what a phone has"
unlinkable=0
for lib in "$out"/*.so; do
  # Not a CPU binary: QDSP6 code, whose libraries are the DSP's own.
  case "${lib##*/}" in libggml-htp-*) continue ;; esac
  while IFS= read -r need; do
    [ -f "$out/$need" ] || [ -f "$sysroot/$need" ] || {
      echo "  ${lib##*/} needs $need, which is neither" >&2
      unlinkable=1
    }
  done < <(llvm-readelf -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
done
[ "$unlinkable" = 0 ] || exit 1

echo "==> $abi"
( cd "$out" && sha256sum ./*.so && ls -l ./*.so )
