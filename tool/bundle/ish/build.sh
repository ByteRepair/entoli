#!/usr/bin/env bash
# Builds the iSH emulator core and the FFI bridge as a static library for iOS,
# producing an XCFramework the app links. iSH runs the whole guest in-process
# (see ios/CLAUDE.md), so this is a library, not an executable the app spawns.
#
#   tool/bundle/ish/build.sh
#
# Needs macOS and Xcode (xcrun, the iOS SDK). Produces, in dist/:
#   IshCore.xcframework  — the emulator core + bridge, for device and sim.
#
# Not run by the app build, the way tool/bundle/build.sh is not: without it an
# iOS build has no emulator to link. See "The iSH driver" in ios/CLAUDE.md.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="$here/src"
bridge="$here/ish_bridge.c"
work=${WORK_DIR:-$here/build}
out=${OUT_DIR:-$here/dist}
jobs=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}

# Ensure the iSH submodule is checked out. A contributor or CI that cloned
# without --recurse-submodules has an empty src/ here; init it shallowly so
# the build is self-contained the way tool/bundle/build.sh is for Android.
if [ ! -f "$src/kernel/calls.h" ]; then
    git submodule update --init --recursive --depth 1
fi
if [ ! -f "$src/kernel/calls.h" ]; then
    echo "iSH source is not present. Run 'git submodule update --init --recursive' from the repo root." >&2
    exit 1
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
# deps/libarchive submodule).
fakefsify_src=(tools/fakefsify.c)

# The emulator (asbestos) is hand-written assembly gadgets per host arch. The
# iOS device and the simulator are both arm64, so gadgets-arm64 is the one.
emu_src=(
  emu/tlb.c emu/fpu.c emu/vec.c emu/mmx.c emu/float80.c
  asbestos/asbestos.c asbestos/gen.c asbestos/helpers.c
  asbestos/gadgets-arm64/entry.S asbestos/gadgets-arm64/memory.S
  asbestos/gadgets-arm64/control.S asbestos/gadgets-arm64/math.S
  asbestos/gadgets-arm64/bits.S asbestos/gadgets-arm64/string.S
  asbestos/gadgets-arm64/misc.S
)

all_src=("${kernel_src[@]}" "${fakefs_src[@]}" "${fakefsify_src[@]}" "${emu_src[@]}" "$bridge")

# Flags shared across every target. iSH's meson build sets c_std=gnu11 and
# -Wno-switch; the asbestos gadgets are assembly.
common_cflags=(
  -std=gnu11 -Wno-switch -Wno-implicit-fallthrough
  -DISH_IOS=1 -DENGINE_ASBESTOS=1
  -I"$src"
)

build_lib() {
  local sdk=$1 arch=$2 outname=$3
  local destdir="$work/$outname"
  mkdir -p "$destdir"
  local sdkroot; sdkroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  local cflags=("${common_cflags[@]}" -isysroot "$sdkroot" \
    -arch "$arch" -fPIC -O2 -g \
    -I"$src/deps/libarchive/libarchive")
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

rm -rf "$out"
mkdir -p "$out"

# Device (arm64) and simulator (arm64, x86_64). The simulator x86_64 slice is
# what an Intel Mac runs; arm64 sim is Apple Silicon.
build_lib iphoneos arm64 device
build_lib iphonesimulator arm64 sim-arm64
build_lib iphonesimulator x86_64 sim-x86_64

xcodebuild -create-xcframework \
  -library "$out/libishcore_device.a" \
  -library "$out/libishcore_sim-arm64.a" \
  -library "$out/libishcore_sim-x86_64.a" \
  -output "$out/IshCore.xcframework"

echo "Built $out/IshCore.xcframework"
