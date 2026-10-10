# The iOS half

## The icon

`Runner/entoli.icon/AGENTS.md` is a symlink into the macos half: the Icon
Composer package both Apples compile the app icon from — one file for iOS and
macOS, its layers generated from `assets/icons/cookie.svg`, the launcher
switching being Android's `activity-alias` alone so only the default has a
copy here.

## Why no host shell

iOS refuses an app a child process. `fork`, `exec` and `posix_spawn` are denied
by the sandbox, and no entitlement — App Store, AltStore or Developer Mode —
changes that short of a jailbreak. So the shell every other platform has, the
one that does `Process.start` of `/bin/sh` or a bundled `proot`, cannot work
here at all. An iOS build with no answer to that is one where every command the
agent runs fails, which is the whole of why this platform ships an emulator
instead.

The emulator is iSH, a git submodule under `tool/ios/ish/src/` (shallow —
`shallow = true` in `.gitmodules`, so `git submodule update --init` fetches
one commit, not the full history) and built as a static library linked into
the app (see "The iSH driver" below). It runs a Linux
userspace **in-process**: no child process, and no writable-executable memory
either, which is the other iOS ban. iSH's threaded-code interpreter is a table
of function pointers with tail-calls rather than a JIT that emits machine code,
which is exactly what lets it run on a stock, non-jailbroken device. The guest
is an i386 Alpine — see "The rootfs" — and not the arm64 one Android uses,
because iSH emulates x86 and not the device's own architecture.

## The iSH driver

`IshShell` is the iOS `Shell`, the way `LocalShell` is the desktop-and-Android
one. It does not extend `LocalShell`: `LocalShell`'s persistent session is a
single child process whose stdin is fed base64 lines and whose stdout is read
for a marker, and iOS has no child process to be. `IshShell` carries its own
session map, each entry an iSH handle driven through `dart:ffi`, on a
long-lived background isolate so a guest command does not block the UI.

The dispatcher script `LocalShell` uses — the trap that turns a Ctrl-C into a
130 while the shell survives, the `EXIT` trap that reports where `exit` left
it, the base64 line that keeps a multi-line command from stealing the queue —
is shared, lifted to `lib/domain/shell.dart` so both shells read one source of
truth. iSH runs it inside the guest's own `/bin/sh`, which is what makes a `cd`
or an `export` in one command stick for the next, the same contract the agent
is told on every other platform.

## Bring-up status

The app launches and runs on an iOS simulator, with the emulator linked: the
startup chain (data directory, secrets, the bundled skills' self-heal) runs
end to end, the UI renders, and the FFI entry points resolve at runtime —
`ishLinked` true, `ishInitFn`/`ishRunFn`/`ishFakefsifyFn` non-null, evaluated
in the running app over the VM service. What is left:

1. **Install a rootfs and run a command.** The rootfs half is done: the
   Terminal page's Alpine download ran end to end on the simulator —
   fetch, SHA-256 check, the in-process unpack, tarball deleted, `.complete`
   marker written, row installed. The unpack survives all three directory
   states the store can produce — the target absent, an empty one created
   for the download, and the store's real layout where the tarball sits
   *inside* the target it names — all rc 0 through the shipped archive. The
   bridge moves the tarball beside the target before the import (upstream's
   `fakefs_import` begins with `mkdir`, which dies on the pre-created
   target) and restores it to where the caller left it in both outcomes: on
   failure so a retry does not re-download, on success so the store finds
   the tarball it deletes. Download failures are now logged through
   `logFailure` from the shared `Downloads` notifier, where they used to
   reach only the failing row. What remains is the first command: a `bash`
   run exercises `ish_boot`/`ish_session_init`/`ish_session_run` — the
   first real run of the emulator itself.
2. **The link wiring is xcconfig, not CocoaPods.** `ios/Flutter/Debug.xcconfig`
   and `Release.xcconfig` force-load the right `IshCore.xcframework` slice per
   SDK and name the system libraries (`-lz -lbz2 -lxml2 -lsqlite3 -liconv`)
   the podspec would have carried; there is no Podfile. The framework itself
   is built by `tool/ios/ish/build.sh` (LLVM's clang and lld wanted for the
   vdso; `brew install llvm lld`, both keg-only and not on PATH by default).
   `tools/fakefsify.c` is deliberately not compiled — its `main()` collides
   with the app's; `tools/fakefs.c`'s `fakefs_import` is what
   `ish_fakefsify` wraps.
3. **Then the runtime path is testable for real**: the IshShell/FFI/dispatcher
   chain against a real guest on a device, which a simulator can only begin
   to answer.

Known from the review, still open: the interrupt/timeout path is structurally
dead — one isolate serves every session and blocks inside the synchronous FFI
`runFn`, so an interrupt message queues behind the run it is meant to end —
and `_ensure()` has a spawn race (two concurrent first inits orphan one
isolate). Both are acceptable for a first bring-up; both need the
architecture rework before real use.

## The rootfs

The Alpine a device downloads is an **i386** minirootfs, a separate entry in
`Rootfs.images` under the `"ios"` ABI key — not the arm64 one Android fetches,
because iSH emulates x86 and cannot run an arm64 binary. It is unpacked into
iSH's fakefs, the SQLite-backed filesystem iSH models in-process, and the
unpacking cannot use the system `tar` (the same exec ban): `FileRootfsStore`'s
`tar` callback is iSH's own `fakefsify` tool, linked in, which converts a
libarchive tarball into the fakefs layout without spawning anything.

## The workspace inside the guest

iSH has its own userspace filesystem (the fakefs the rootfs is unpacked into),
and the model is told the same masked view of the workspace Android's proot
guest gets: the project workspace is bound at `/root` (`bind_workspace` in
`ish_bridge.c`, a `realfs` mount — the same clean path proot's
`-b $home:/root` gives it), so the chat's own workspace is
`/root/chats/<id>`, `HOME` is `/root`, and the prompt says `~`. The prompt,
the file tools and the shell all read the mask from the same two members —
`IshShell.guestRoot` and `IshShell.homeFor` — the way they read the driver's
on Android, and `resolveWorkspacePath` translates `/root/...` back to the
host paths the app's own `dart:io` uses.

Beside the mask, the app's whole data directory is bound at its own absolute
host path (`bind_data_dir`, a second `realfs` mount), so a host-shaped path
still resolves inside the guest — the fallback spelling, not the one the
model is given. Both binds are made once per process, in `ish_session_init`,
before the shell's working directory is opened; a bind that does not land is
logged and the shell starts anyway. The fakefs root is mounted by
`mount_root(&fakefs, rootfsDir/data)` in `ish_bridge.c`'s `ish_boot`, the
way the app's own boot mounts `<root>/data` (`fakefs_mount` asserts the
source ends in `data` and derives the sibling `meta.db` from it).

iSH's `iosfs` (`mount -t ios`) is the mechanism for a user-picked external
folder, the Files-app picker a `UIDocumentPickerViewController` presents. It is
not used here: the agent's workspace is the app's own data dir, which needs none
of that. It is reserved for a future optional feature, and reusing it would mean
substituting Entoli's own view controller for the `currentTerminalViewController`
iSH's shell expects as the picker's presenter.
