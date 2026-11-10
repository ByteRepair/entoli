#!/usr/bin/env bash
# Builds the iSH emulator core and the FFI bridge as a static library for iOS,
# producing an XCFramework the app links. iSH runs the whole guest in-process
# (see ios/AGENTS.md), so this is a library, not an executable the app spawns.
#
# Two cores are built into the one framework: i386 (asbestos, the iSH that
# always was) and x86-64 (blink, "blinkish"). They share every kernel and fs
# source, compiled twice with different guest and engine defines, so their
# thousands of internal symbols are the same names. The i386 core keeps its
# symbols global; the blinkish core is partially linked (`ld -r`) with an
# exported-symbols list naming only its `blinkish_*` bridge entry points, so
# every internal symbol becomes local and the two cores never meet at the
# final link. See docs/blinkish.md.
#
#   tool/ios/ish/build.sh
#
# Needs macOS and Xcode (xcrun, the iOS SDK) plus LLVM's clang and lld for the
# i386 vdso (brew install llvm; the script says so if they are missing).
# Produces, in dist/:
#   IshCore.xcframework  — both emulator cores + the bridge, device and sim.
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

# The source files the kernel=ish build compiles, taken from src/meson.build's
# `src` list. Platform host is darwin (iOS is Darwin), so platform/darwin.c.
kernel_src=(
  kernel/init.c kernel/errno.c kernel/calls.c kernel/memory.c kernel/user.c
  kernel/vdso.c kernel/task.c kernel/group.c kernel/log.c kernel/fork.c
  kernel/exec.c kernel/exit.c kernel/time.c kernel/mmap.c kernel/uname.c
  kernel/tls.c kernel/futex.c kernel/getset.c kernel/signal.c
  kernel/resource.c kernel/random.c kernel/misc.c kernel/eventfd.c kernel/signalfd.c
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

# The i386 emulator (asbestos) is hand-written assembly gadgets per host arch.
# The iOS device and the simulator are both arm64 (cpu_family aarch64, which is
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

# The x86-64 emulator is blink's interpreter, the same list src/meson.build
# builds with -Dengine=blink. Pure C, so it compiles for arm64 like any other.
blink_files=(
  abort address alu alu1 alu2 alui assert bcd bit bitscan bmi2 bus clmul
  cmpxchg cpuid crc32 cvt divmul errfd errno flags fpu instruction jit ldbl
  legacy log machine memory mmx modrm op101 popcount pte32 random rdrand reset
  sse sse2 sse4 ssefloat ssemov stack string time uop x86 xadd xchg breg vigna dll
  memccpy
)
blink_src=(emu/blink/interp.c)
for f in "${blink_files[@]}"; do
  blink_src+=("deps/blink/blink/$f.c")
done

# Flags shared across every target. iSH's meson build sets c_std=gnu11 and
# -Wno-switch; LOG_HANDLER_DPRINTF is the handler the default options pick.
common_cflags=(
  -std=gnu11 -Wno-switch -Wno-implicit-fallthrough
  -DLOG_HANDLER_DPRINTF=1
  -I"$src"
)

# blink's own configuration, the flags meson.build's blink static_library
# carries plus its config.h directory. config.h (emu/blink/config) holds the
# interpreter's host probes and its DISABLE_* defines; it must be first on the
# include path, because libarchive's deps/config.h is also on it (via the
# shared -I"$src/deps") and would otherwise shadow blink's, leaving HAVE_JIT
# set and the JIT's iOS-banned pthread_jit_write_protect_np compiled.
blink_cflags=(
  -DNOLINEAR -DNDEBUG -D_GNU_SOURCE -D_DARWIN_C_SOURCE -D_DEFAULT_SOURCE
  -D_BSD_SOURCE -D_FILE_OFFSET_BITS=64
  -Wno-unused-parameter -Wno-sign-compare -Wno-missing-field-initializers
  -I"$src/emu/blink/config" -I"$src/deps/blink"
)

# The bridge's public entry points, without their prefix: ish_* in the i386
# core, renamed to blinkish_* when the x86-64 core is built. Compiling the same
# source twice with a -D rename is what gives the second core its bridge
# without forking the file. The renames and the x86-64 core's export list are
# both made from this one list. fakefsify is not among them: the rootfs unpack
# is guest-independent (one fakefs format), so only the i386 core has it.
bridge_entry_points=(
  boot
  session_init session_drain_wake session_write_stdin session_poll
  session_read session_interrupt session_hangup session_destroy
  pipe_init pipe_write pipe_close_input pipe_poll pipe_read pipe_terminate
  pipe_hangup pipe_destroy pipe_exit_code
)
blinkish_bridge_renames=()
for e in "${bridge_entry_points[@]}"; do
  blinkish_bridge_renames+=("-Dish_$e=blinkish_$e")
done

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
    -I"$src" -MD -MF "$destdir/cpu-offsets.h.d" -MQ "$destdir/cpu-offsets.h" \
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

# The flags every slice's objects are compiled with: the common ones, the
# SDK, the target triple, and the include paths libarchive and the vdso need.
slice_cflags() {
  local sdk=$1 target=$2 outname=$3
  local sdkroot; sdkroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  printf '%s\n' "${common_cflags[@]}" \
    -isysroot "$sdkroot" -target "$target" -fPIC -O2 -g \
    -I"$work/offsets-$outname" -I"$work" \
    -DHAVE_CONFIG_H -I"$src/deps" -I"$src/deps/libarchive/libarchive"
}

# Compile one source into $destdir, answering its object path. The bridge is
# ours; the rest are under src/. The x86-64 core renames the bridge's entry
# points and adds the blink flags and guest/engine defines.
compile_one() {
  local destdir=$1 f=$2
  local extra=("${@:3}")
  local rel="${f//\//_}"
  local outobj="$destdir/$rel.o"
  if [[ "$f" == "$bridge" ]]; then
    cc "${extra[@]}" -c "$f" -o "$outobj"
  else
    cc "${extra[@]}" -c "$src/$f" -o "$outobj"
  fi
  printf '%s\n' "$outobj"
}

# The i386 core: the kernel + fakefs + libarchive + fakefsify + asbestos + the
# bridge, one static lib per slice.
build_i386_lib() {
  local sdk=$1 outname=$2 target=$3
  local destdir="$work/$outname"
  mkdir -p "$destdir"
  local -a cflags; cflags=($(slice_cflags "$sdk" "$target" "$outname"))
  cflags+=(-DENGINE_ASBESTOS=1)
  local objs=()
  local srcs=("${kernel_src[@]}" "${fakefs_src[@]}" "${libarchive_src[@]}"
    "${fakefsify_src[@]}" "${emu_src[@]}" "$bridge")
  for f in "${srcs[@]}"; do
    objs+=("$(compile_one "$destdir" "$f" "${cflags[@]}")")
  done
  libtool -static -o "$out/libishcore_$outname.a" "${objs[@]}"
}

# The x86-64 core: the same kernel and fakefs sources, plus blink's interpreter and the engine glue, compiled with the x86-64 guest
# and blink engine, then partially linked with only the blinkish_* bridge
# symbols exported so its internals stay local. One static lib per slice.
build_blinkish_lib() {
  local sdk=$1 outname=$2 target=$3
  local destdir="$work/$outname"
  mkdir -p "$destdir"
  local sdkroot; sdkroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  local -a cflags; cflags=($(slice_cflags "$sdk" "$target" "$outname"))
  cflags+=(-DENGINE_BLINK=1 -DGUEST_X86_64=1)
  local objs=()
  local srcs=("${kernel_src[@]}" "${fakefs_src[@]}" "emu/tlb.c"
    "emu/blink/engine.c")
  for f in "${srcs[@]}"; do
    objs+=("$(compile_one "$destdir" "$f" "${cflags[@]}")")
  done
  # blink's sources need blink's config.h (DISABLE_JIT and friends) ahead of
  # libarchive's deps/config.h, which the shared cflags put on the include
  # path; they need nothing of libarchive, so they get their own flags with
  # the blink config first and no deps/ include at all.
  local -a bcflags; bcflags=("${blink_cflags[@]}")
  bcflags+=(-isysroot "$sdkroot" -target "$target" -fPIC -O2 -g)
  bcflags+=("${common_cflags[@]}")
  for f in "${blink_src[@]}"; do
    objs+=("$(compile_one "$destdir" "$f" "${bcflags[@]}")")
  done
  # The bridge, with its entry points renamed to blinkish_*.
  objs+=("$(compile_one "$destdir" "$bridge" "${cflags[@]}" "${blinkish_bridge_renames[@]}")")

  # Partial-link: keep only the blinkish_* entry points global; every internal
  # symbol — the kernel's syscalls, fs ops, blink's interpreter — becomes local
  # so it cannot collide with the i386 core's same-named symbols at the final
  # link. The exported list uses the C underscore macOS mangles symbols with.
  local exportlist="$work/blinkish-exports-$outname.txt"
  printf '_blinkish_%s\n' "${bridge_entry_points[@]}" > "$exportlist"
  local partial="$destdir/blinkish.o"
  ld -r "${objs[@]}" -exported_symbols_list "$exportlist" -o "$partial"
  # The partial object is a static lib on its own, but it sits beside the
  # i386 core under one framework, so it is archived the same way.
  libtool -static -o "$out/libblinkish_$outname.a" "$partial"
}

rm -rf "$out"
mkdir -p "$out"

# Device (arm64) and simulator (arm64), both cores each.
gen_offsets iphoneos arm64-apple-ios14.0 device
build_i386_lib iphoneos device arm64-apple-ios14.0
build_blinkish_lib iphoneos device arm64-apple-ios14.0

gen_offsets iphonesimulator arm64-apple-ios14.0-simulator sim-arm64
build_i386_lib iphonesimulator sim-arm64 arm64-apple-ios14.0-simulator
build_blinkish_lib iphonesimulator sim-arm64 arm64-apple-ios14.0-simulator

# Both cores, one framework per slice. The app's Ish.xcconfig force-loads each
# slice's single library by its canonical name (libishcore_device.a and
# libishcore_sim-arm64.a), so the two cores are merged into that one archive:
# the i386 core's symbols are global, the blinkish core's are local except its
# blinkish_* entry points, so nothing collides. The merge writes a temp and
# moves it over the i386 archive, whose name is the input.
for name in device sim-arm64; do
  libtool -static \
    -o "$out/libishcore_${name}_merged.a" \
    "$out/libishcore_${name}.a" "$out/libblinkish_${name}.a"
  mv "$out/libishcore_${name}_merged.a" "$out/libishcore_${name}.a"
done

xcodebuild -create-xcframework \
  -library "$out/libishcore_device.a" \
  -library "$out/libishcore_sim-arm64.a" \
  -output "$out/IshCore.xcframework"

echo "Built $out/IshCore.xcframework"
