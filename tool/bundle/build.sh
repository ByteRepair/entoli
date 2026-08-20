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
# architecture can run 32-bit guests).
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

echo "==> $abi"
( cd "$out" && sha256sum ./*.so && ls -l ./*.so )
