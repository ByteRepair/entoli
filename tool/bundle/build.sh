#!/usr/bin/env bash
# Builds git and proot for Android, one ABI at a time, and lays the result out
# the way the app packages it: an executable named lib*.so, because the
# installer only extracts files matching that from an APK, and the native
# library directory is the one place an app is allowed to exec from. See
# "Bundled tools" in CLAUDE.md.
#
#   ANDROID_NDK_ROOT=~/.android/ndk/28.2.13676358 tool/bundle/build.sh arm64-v8a
#
# Output, stripped, in dist/<abi>: libgit.so, libgit-remote-http.so, libproot.so
# and its loader (libproot-loader.so, plus libproot-loader32.so where the
# architecture can run 32-bit guests), and llama.cpp's server as
# libllama-server.so with the libraries it loads beside it.
#
# The NPU is opt-in and needs a licensed SDK, so it is off by default:
#
#   HEXAGON_SDK_ROOT=~/Qualcomm/Hexagon_SDK/6.6.0.1 tool/bundle/build.sh arm64-v8a
#
# See "Running a model on the device" in CLAUDE.md for what that
# buys and what it costs.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/versions.sh"

abi=${1:?usage: build.sh <abi>}
work=${WORK_DIR:-$here/build}
out=${OUT_DIR:-$here/dist}/$abi
ndk=${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must point at an NDK}
jobs=${JOBS:-$(nproc)}

# The API level the app itself is built against. Below this the binaries would
# link against symbols a supported device may not have.
api=26

# `triple` names the compiler, `host` names the platform for autoconf, and for
# 32-bit arm the two disagree.
case "$abi" in
  arm64-v8a)   triple=aarch64-linux-android;    host=aarch64-linux-android; openssl_target=android-arm64 ;;
  armeabi-v7a) triple=armv7a-linux-androideabi; host=arm-linux-androideabi; openssl_target=android-arm ;;
  x86_64)      triple=x86_64-linux-android;     host=x86_64-linux-android;  openssl_target=android-x86_64 ;;
  *) echo "unknown abi: $abi" >&2; exit 2 ;;
esac

bin=$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
export CC=$bin/$triple$api-clang
export AR=$bin/llvm-ar
export RANLIB=$bin/llvm-ranlib
export STRIP=$bin/llvm-strip
export PATH=$bin:$PATH
# Android 15 wants 16 KB-aligned segments, and a phone that enforces it will not
# load a library built for 4 KB pages.
export CFLAGS="-O2 -fPIC -Wl,-z,max-page-size=16384"

# **llama.cpp is arm64 only, and that is a size decision.** The server and its
# libraries are about 18 MB stripped, against git's 12, and three ABIs of it
# would put 56 MB into the universal APK. Nothing is lost: a 32-bit phone cannot
# map a two-gigabyte model at all, and x86_64 Android is an emulator. A build
# without it leaves `LocalLlm.available` false, which the settings page says.
llama_abis=${LLAMA_ABIS:-arm64-v8a}
if [[ " $llama_abis " == *" $abi "* ]]; then llama=yes; else llama=no; fi

mkdir -p "$work" "$out"

fetch() {
  local url=$1 file=$2 sha=$3
  if [ ! -f "$work/$file" ]; then
    curl -fsSL --retry 3 -o "$work/$file.part" "$url"
    mv "$work/$file.part" "$work/$file"
  fi
  echo "$sha  $work/$file" | sha256sum -c - >/dev/null
}

echo "==> fetching sources"
fetch "$OPENSSL_URL" "openssl.tar.gz" "$OPENSSL_SHA256"
fetch "$CURL_URL" "curl.tar.gz" "$CURL_SHA256"
fetch "$GIT_URL" "git.tar.gz" "$GIT_SHA256"
fetch "$TALLOC_URL" "talloc.tar.gz" "$TALLOC_SHA256"
fetch "$PROOT_URL" "proot.tar.gz" "$PROOT_SHA256"
if [ "$llama" = yes ]; then fetch "$LLAMA_CPP_URL" "llama.tar.gz" "$LLAMA_CPP_SHA256"; fi

# Unpacked and built once per ABI. A second run reuses what is there, which is
# what makes iterating on the git step bearable; CI starts from an empty tree
# either way.
src=$work/$abi
mkdir -p "$src"
[ -d "$src/openssl-$OPENSSL_VERSION" ] || tar -C "$src" -xf "$work/openssl.tar.gz"
[ -d "$src/curl-$CURL_VERSION" ] || tar -C "$src" -xf "$work/curl.tar.gz"
[ -d "$src/git-$GIT_VERSION" ] || tar -C "$src" -xf "$work/git.tar.gz"
[ -d "$src/talloc-$TALLOC_VERSION" ] || tar -C "$src" -xf "$work/talloc.tar.gz"
[ -d "$src/proot-$PROOT_VERSION" ] || tar -C "$src" -xf "$work/proot.tar.gz"
if [ "$llama" = yes ] && [ ! -d "$src/llama.cpp-$LLAMA_CPP_VERSION" ]; then
  tar -C "$src" -xf "$work/llama.tar.gz"
fi

echo "==> openssl $OPENSSL_VERSION"
(
  cd "$src/openssl-$OPENSSL_VERSION"
  [ -f libcrypto.a ] && exit 0
  ANDROID_NDK_ROOT=$ndk ./Configure "$openssl_target" "-D__ANDROID_API__=$api" \
    no-shared no-tests no-docs >/dev/null
  make -j"$jobs" build_libs >/dev/null
)

echo "==> curl $CURL_VERSION"
(
  cd "$src/curl-$CURL_VERSION"
  [ -f lib/.libs/libcurl.a ] && exit 0
  ./configure --host="$host" --disable-shared --enable-static \
    --without-libpsl --without-libidn2 --without-brotli --without-zstd \
    --without-nghttp2 --disable-ldap \
    --with-openssl="$src/openssl-$OPENSSL_VERSION" \
    CPPFLAGS="-I$src/openssl-$OPENSSL_VERSION/include" \
    LDFLAGS="-L$src/openssl-$OPENSSL_VERSION" >/dev/null
  make -j"$jobs" >/dev/null
)

echo "==> git $GIT_VERSION"
(
  cd "$src/git-$GIT_VERSION"
  # Three adjustments, and only three: bionic has no pthread cancellation (the
  # header below), folds pthread and rt into libc, and git's own SHA
  # implementations stand in for OpenSSL's, which it would otherwise want at
  # build time for nothing we use.
  make -j"$jobs" \
    CC="$CC" AR="$AR" \
    CFLAGS="$CFLAGS -include $here/android-compat.h -I$src/curl-$CURL_VERSION/include -I$src/openssl-$OPENSSL_VERSION/include" \
    CURL_LDFLAGS="$src/curl-$CURL_VERSION/lib/.libs/libcurl.a $src/openssl-$OPENSSL_VERSION/libssl.a $src/openssl-$OPENSSL_VERSION/libcrypto.a -lz" \
    PTHREAD_LIBS= NEEDS_LIBRT= \
    NO_OPENSSL=1 NO_GETTEXT=1 NO_ICONV=1 NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_EXPAT=1 \
    uname_S=Linux ac_cv_fread_reads_directories=no ac_cv_snprintf_returns_bogus=no \
    git git-remote-http >/dev/null
  "$STRIP" -o "$out/libgit.so" git
  "$STRIP" -o "$out/libgit-remote-http.so" git-remote-http
)

echo "==> talloc $TALLOC_VERSION"
(
  cd "$src/talloc-$TALLOC_VERSION"
  [ -f "$src/libtalloc.a" ] && exit 0
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
  "$AR" rcs "$src/libtalloc.a" talloc.o
)

echo "==> proot $PROOT_VERSION"
(
  cd "$src/proot-$PROOT_VERSION"
  # Upstream leaves out an include and clang refuses an implicit declaration.
  grep -q "string.h" src/extension/ashmem_memfd/ashmem_memfd.c ||
    sed -i "3i #include <string.h>" src/extension/ashmem_memfd/ashmem_memfd.c
  # Through the environment rather than as make arguments: the makefile appends
  # its own -I, -D_GNU_SOURCE and -ltalloc to all three, and a make argument
  # would replace them instead. Without _GNU_SOURCE proot silently loses
  # process_vm_readv and reads the tracee's memory a word at a time.
  export CC AR STRIP
  export OBJCOPY=$bin/llvm-objcopy OBJDUMP=$bin/llvm-objdump
  export CPPFLAGS="-I$src/talloc-$TALLOC_VERSION -DARG_MAX=131072 -DVERSION=\\\"$PROOT_VERSION\\\""
  export CFLAGS="-O2 -fPIC"
  export LDFLAGS="-L$src -Wl,-z,max-page-size=16384"
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
    -DCMAKE_SKIP_INSTALL_RPATH=ON
    # The server downloads models when it is told to; this app does its own
    # downloading, and linking curl here would mean cross-compiling it a second
    # time for a feature nothing reaches.
    -DLLAMA_CURL=OFF
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
  # The NPU, where whoever is building has the SDK for it. Qualcomm's, behind an
  # account, and not redistributable — which is why CI builds without it and why
  # this is a variable rather than a default. Nothing else changes: the backend
  # arrives as two more `libggml-*.so` and the app finds it the same way it
  # finds the CPU's.
  if [ -n "${HEXAGON_SDK_ROOT:-}" ]; then
    cmake_args+=(-DGGML_HEXAGON=ON -DHEXAGON_SDK_ROOT="$HEXAGON_SDK_ROOT")
  fi
  cmake "${cmake_args[@]}" >/dev/null
  cmake --build "$build" -j"$jobs" --target llama-server >/dev/null

  # Named lib*.so because that is all the installer extracts from an APK, which
  # for the executable is also the only way it lands somewhere it may be run
  # from. The libraries keep the names they were linked under — the loader
  # resolves those by name, and renaming one is a server that will not start.
  "$STRIP" -o "$out/libllama-server.so" "$(find "$build" -name llama-server -type f | head -1)"
  shopt -s nullglob
  while IFS= read -r lib; do
    case "$(basename "$lib")" in
      # The DSP-side half of the Hexagon backend, which is not a CPU library at
      # all: it is QDSP6 code, loaded onto the NPU by fastRPC by name out of
      # ADSP_LIBRARY_PATH, and nothing on this side can strip it.
      libggml-htp-*) cp "$lib" "$out/" ;;
      *) "$STRIP" -o "$out/$(basename "$lib")" "$lib" ;;
    esac
  done < <(find "$build" -name "lib*.so" -type f)
)
fi

echo "==> $abi"
( cd "$out" && sha256sum ./*.so && ls -l ./*.so )
