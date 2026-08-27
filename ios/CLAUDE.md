# The iOS half

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

## The rootfs

The Alpine a device downloads is an **i386** minirootfs, a separate entry in
`Rootfs.images` under the `"ios"` ABI key — not the arm64 one Android fetches,
because iSH emulates x86 and cannot run an arm64 binary. It is unpacked into
iSH's fakefs, the SQLite-backed filesystem iSH models in-process, and the
unpacking cannot use the system `tar` (the same exec ban): `FileRootfsStore`'s
`tar` callback is iSH's own `fakefsify` tool, linked in, which converts a
libarchive tarball into the fakefs layout without spawning anything.

## The workspace inside the guest

proot binds the app's data directory into the guest at the same path; iSH has
its own userspace filesystem and no host bind. The equivalent is
`do_mount(&realfs, dataDir, dataDir, "", 0)`, called in `ish_bridge.c`'s
`ish_session_init` after `mount_root(&fakefs, rootfsDir)`. `realfs` is the host
POSIX filesystem type iSH already registers; the app's own data directory is
fully accessible to the app's own process via POSIX, which is how the fakefs
database itself is read and written, so this needs no picker, no
`NSFileCoordinator` and no entitlement. The chat's working directory —
`<dataDir>/projects/<project>/workspace/chats/<id>/` — resolves through
`mount_find` to `realfs`, and every path the app hands the model means the same
thing inside the guest as outside it, the property proot's `-b $dataDir:$dataDir`
buys on Android.

iSH's `iosfs` (`mount -t ios`) is the mechanism for a user-picked external
folder, the Files-app picker a `UIDocumentPickerViewController` presents. It is
not used here: the agent's workspace is the app's own data dir, which needs none
of that. It is reserved for a future optional feature, and reusing it would mean
substituting Entoli's own view controller for the `currentTerminalViewController`
iSH's shell expects as the picker's presenter.
