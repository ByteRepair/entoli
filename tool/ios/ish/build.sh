#!/usr/bin/env bash
# Builds the iSH emulator core and the FFI bridge as a static library for iOS,
# producing an XCFramework the app links. iSH runs the whole guest in-process
# (see ios/AGENTS.md), so this is a library, not an executable the app spawns.
#
#   tool/ios/ish/build.sh
#
# Needs macOS and Xcode (xcrun, the iOS SDK) plus LLVM's clang and lld for the
# i386 vdso (brew install llvm; the script says so if they are missing).
# Produces, in dist/:
#   IshCore.xcframework  — the emulator core + bridge, for device and sim.
#
# Not run by the app build, the way tool/android/build.sh is not: without it an
# iOS build has no emulator to link. See "The iSH driver" in ios/AGENTS.md.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="$here/src"
bridge="$here/ish_bridge.c"
work=${WORK_DIR:-$here/build}
out=${OUT_DIR:-$here/dist}

# Ensure the iSH submodule is checked out. A contributor or CI that cloned
# without --recurse-submodules has an empty src/ here; init it shallowly so
# the build is self-contained the way tool/android/build.sh is for Android.
if [ ! -f "$src/kernel/calls.h" ]; then
    git -C "$here" submodule update --init --recursive --depth 1 -- src
fi
if [ ! -f "$src/kernel/calls.h" ]; then
    echo "iSH source is not present. Run 'git submodule update --init --recursive' from the repo root." >&2
    exit 1
fi

# Read-only mounts that refuse writes, which upstream records and never checks.
# Applied to the submodule's working tree, so the pinned commit stays the one
# named; a tree it is already applied to is left alone.
if ! git -C "$src" apply --reverse --check "$here/patches/read-only-mounts.patch" 2>/dev/null; then
    git -C "$src" apply "$here/patches/read-only-mounts.patch"
fi

# The source files the kernel=ish build compiles, taken from src/meson.build's
# `src` list. Platform host is darwin (iOS is Darwin), so platform/darwin.c.
kernel_src=(
  kernel/init.c kernel/errno.c kernel/calls.c kernel/memory.c kernel/user.c
  kernel/vdso.c kernel/task.c kernel/group.c kernel/log.c kernel/fork.c
  kernel/exec.c kernel/exit.c kernel/time.c kernel/mmap.c kernel/uname.c
  kernel/tls.c kernel/futex.c kernel/getset.c kernel/signal.c
  kernel/resource.c kernel/random.c kernel/misc.c kernel/eventfd.c
  kernel/ipc.c kernel/ptrace.c kernel/fs.c kernel/fs_info.c
  fs/mount.c fs/fd.c fs/inode.c fs/stat.c fs/dir.c fs/generic.c fs/path.c
  fs/real.c fs/fake.c fs/proc.c fs/proc/entry.c fs/proc/ish.c
  fs/proc/root.c fs/proc/pid.c fs/dyndev.c fs/adhoc.c fs/sock.c
  fs/pipe.c fs/sockrestart.c fs/lock.c fs/dev.c fs/mem.c fs/tty.c
  fs/tty-real.c fs/pty.c fs/tmp.c fs/poll.c kernel/poll.c kernel/epoll.c
  util/timer.c util/sync.c util/fifo.c util/fchdir.c platform/darwin.c
)

# The fakefs backend (SQLite-backed rootfs) is a separate lib in the meson
# build; we compile it in directly.
fakefs_src=(fs/fake-db.c fs/fake-migrate.c fs/fake-rebuild.c)

# The rootfs unpack tool. iSH's tools/fakefsify converts a tarball to fakefs
# in-process; the bridge's ish_fakefsify wraps it. Needs libarchive (iSH's
# deps/libarchive submodule) compiled in beside it: iSH's own build links the
# system libarchive on the Mac, which iOS does not ship, so the sources come
# along — the xcodeproj in deps/ builds exactly this set with HAVE_CONFIG_H
# and the config.h at deps/.
libarchive_src=()
while IFS= read -r f; do
  libarchive_src+=("deps/libarchive/libarchive/$f")
done < <(cd "$src/deps/libarchive/libarchive" && ls *.c)
# What the bridge's ish_fakefsify wraps is tools/fakefs.c's fakefs_import;
# fakefsify.c itself is the CLI's main(), which collides with the app's, so
# it stays out.
fakefsify_src=(tools/fakefs.c)

# The emulator (asbestos) is hand-written assembly gadgets per host arch. The
# iOS device and the simulator are both arm64 (cpu_family aarch64, which is
# the gadgets-aarch64 directory — meson picks it by host_machine.cpu_family),
# and they are the only slice built: an x86_64 simulator slice would need a
# second gadget set that does not exist, so it is not offered.
emu_src=(
  emu/tlb.c emu/fpu.c emu/vec.c emu/mmx.c emu/float80.c
  asbestos/asbestos.c asbestos/gen.c asbestos/helpers.c
  asbestos/gadgets-aarch64/entry.S asbestos/gadgets-aarch64/memory.S
  asbestos/gadgets-aarch64/control.S asbestos/gadgets-aarch64/math.S
  asbestos/gadgets-aarch64/bits.S asbestos/gadgets-aarch64/string.S
  asbestos/gadgets-aarch64/misc.S
)

# Flags shared across every target. iSH's meson build sets c_std=gnu11 and
# -Wno-switch; LOG_HANDLER_DPRINTF is the handler the default options pick.
common_cflags=(
  -std=gnu11 -Wno-switch -Wno-implicit-fallthrough
  -DENGINE_ASBESTOS=1 -DLOG_HANDLER_DPRINTF=1
  -I"$src"
)

# cpu-offsets.h is generated, not checked in: meson builds it from
# asbestos/offsets.c via tools/staticdefine.sh before anything that includes
# gadgets-generic.h compiles. Same recipe here: compile with the header that
# prints the offsets, then sed the .ascii directives into #defines.
gen_offsets() {
  local sdk=$1 target=$2 outname=$3
  local destdir="$work/offsets-$outname"
  mkdir -p "$destdir"
  local sdkroot; sdkroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  clang -S -std=gnu11 -isysroot "$sdkroot" -target "$target" -O2 \
    -I"$src" -MD -MQ "$destdir/cpu-offsets.h.d" \
    "$src/asbestos/offsets.c" -include "$src/tools/staticdefine.h" -o - |
  sed -ne 's:^[[:space:]]*\.ascii[[:space:]]*"\(.*\)".*:\1:;
           /^->/{s:->#\(.*\):/* \1 */:;
           s:^->\([^ ]*\) [\$$#]*\([^ ]*\) \(.*\):#define \1 \2 /* \3 */:;
           s:->::; p;}' > "$destdir/cpu-offsets.h"
}

# The vdso is an i386 ELF shared library the kernel .incbin's. It needs a
# clang with an i386-linux target and lld — LLVM's, not Xcode's.
build_vdso() {
  local outelf="$work/vdso/libvdso.so.elf"
  mkdir -p "$work/vdso"
  local vdso_cc=""
  for candidate in /opt/homebrew/opt/llvm/bin/clang /usr/local/opt/llvm/bin/clang clang; do
    if "$candidate" -target i386-linux -fuse-ld=lld -shared -nostdlib \
        -x c /dev/null -o /dev/null 2>/dev/null; then
      vdso_cc=$candidate
      break
    fi
  done
  if [ -z "$vdso_cc" ]; then
    echo "Could not find a usable i386 vdso compiler." >&2
    echo "Install LLVM (brew install llvm) so clang -target i386-linux -fuse-ld=lld works." >&2
    exit 1
  fi
  "$vdso_cc" -target i386-linux -fuse-ld=lld \
    -o "$outelf" "$src/vdso/vdso.S" "$src/vdso/vdso.c" \
    -nostdlib -Wl,-T,"$src/vdso/vdso.lds" -Wl,--hash-style,sysv -shared -fPIC
}

build_vdso

build_lib() {
  local sdk=$1 outname=$2
  local destdir="$work/$outname"
  mkdir -p "$destdir"
  local sdkroot; sdkroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  # A deployment target at or below the app's: without it every object
  # carries the SDK's own minimum and linking them into the app fails on the
  # version check. Simulator slices get the -simulator suffix clang wants.
  local minios=14.0
  local target
  if [ "$sdk" = iphoneos ]; then
    target="arm64-apple-ios$minios"
  else
    target="arm64-apple-ios$minios-simulator"
  fi
  # The vdso is embedded by kernel/vdso.c's `.incbin "vdso/libvdso.so.elf"`,
  # which resolves against the include path — so the path added is $work, the
  # parent of the vdso/ directory the build above writes into.
  local cflags=("${common_cflags[@]}" -isysroot "$sdkroot" \
    -target "$target" -fPIC -O2 -g \
    -I"$work/offsets-$outname" -I"$work" \
    -DHAVE_CONFIG_H -I"$src/deps" -I"$src/deps/libarchive/libarchive")
  # Compile each .c to a .o, then the assembly gadgets the same way.
  local objs=()
  for f in "${all_src[@]}"; do
    local rel="${f//\//_}"
    # The bridge is ours; the rest are under src/.
    if [[ "$f" == "$bridge" ]]; then
      cc "${cflags[@]}" -c "$f" -o "$destdir/$rel.o"
    else
      cc "${cflags[@]}" -c "$src/$f" -o "$destdir/$rel.o"
    fi
    objs+=("$destdir/$rel.o")
  done
  libtool -static -o "$out/libishcore_$outname.a" "${objs[@]}"
}

all_src=("${kernel_src[@]}" "${fakefs_src[@]}" "${libarchive_src[@]}"
  "${fakefsify_src[@]}" "${emu_src[@]}" "$bridge")

# Offsets are generated per slice: the printer compiles against that slice's
# SDK target, and the .h lands in the include path build_lib adds.
rm -rf "$out"
mkdir -p "$out"

# Device (arm64) and simulator (arm64).
gen_offsets iphoneos arm64-apple-ios14.0 device
build_lib iphoneos device
gen_offsets iphonesimulator arm64-apple-ios14.0-simulator sim-arm64
build_lib iphonesimulator sim-arm64

xcodebuild -create-xcframework \
  -library "$out/libishcore_device.a" \
  -library "$out/libishcore_sim-arm64.a" \
  -output "$out/IshCore.xcframework"

echo "Built $out/IshCore.xcframework"