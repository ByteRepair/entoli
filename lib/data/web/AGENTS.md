# What a browser can reach

## The browser's Linux

A page cannot start a process, so the web build brings a machine: v86, an
x86 emulator with a JIT to WebAssembly, booting an i386 Alpine the site serves
beside the app. It is the iOS answer (an emulated Linux in-process, see "Why
no host shell" in `ios/AGENTS.md`) in a browser's terms, and to the rest of the
app it is one more `Shell`: `GuestShell` (`guest_shell.dart`), wired in
`core/platform/web/platform.dart` where `UnavailableShell` used to be.

**Slow is the deal.** Interpreted x86 runs a Python loop of a million additions
in about five seconds. The prompt says so (`BrowserLinux.describe`), along with
the other fact a model would otherwise find out by waiting: **there is no
network.** A guest's packets would leave as the page's `fetch`es, and no
package mirror, git host or PyPI answers a page's origin, so `apk add` cannot
work and nothing pretends it can. What the agent reaches for is installed in
the image instead — git, python3, bash, coreutils, ripgrep, jq, make — and the
list is the Containerfile's.

### Where it runs, and what it is made of

The emulator runs in a worker (`web/linux/worker.js`), not on the page's
thread: a guest busy for a minute would otherwise be a minute without a frame.
The worker and the page trade two kinds of message, the mux's serial lines and
the guest's 9p requests, and nothing else crosses.

What the site serves is `linux/image/`, written by `tool/web/linux/build.sh`
and not in the repository: the v86 runtime and its BIOS, the Alpine kernel and
initramfs, and the root disk, an ext4 image cut into 1 MiB zstd chunks that
v86 fetches as the guest reads them. A boot pulls a few megabytes of the disk
and a session a few more; the 51 MB of chunks are never fetched whole. Writes
to the disk stay in the page's memory, so what a command does outside the
app's files — `/usr/local`, `/etc`, a file in `/tmp` — is gone at a reload.
That is the one thing the Terminal settings section says about it.

Everything under the image's directory is in a subdirectory named for its
contents, which `manifest.json` names. The chunks are named by offset, and
Pages caches for ten minutes: under one fixed name, a deploy would leave
browsers reading half of the old disk and half of the new.

`build.sh` needs podman or docker and nothing else on the host; CI's Pages job
runs it before `flutter build web`, which copies `web/` into the site. A site
built without it has no `manifest.json`, `BrowserLinux.probe` finds none, and
the shell answers `canRunCommands` false — the browser without a terminal it
was before, rather than a terminal that fails at its first command.

### The mux

One serial line (`ttyS1`) carries every process: `entoli-mux`
(`tool/web/linux/entoli-mux.c`) is PID 1 once `entoli-init` has mounted what a
system needs, and frames spawn, stdin, signals, output and exit codes per
process id, one line each, base64 where the bytes are not text.
`GuestMux` (`guest_mux.dart`) is the page's end, and `GuestProcess` is a
`Process` in all the ways `GuestShell` needs. Two chats' shells and a
sub-agent's one-shots run at once over it.

The mux never lets the line back up. A guest's tty drops what arrives while
nobody reads it, so stdin for a child that is not reading is held in the mux,
not left in the kernel's buffer, and output is read in bounded rounds so a
chatty child cannot starve the read of the line.

`GuestShell` keeps `LocalShell`'s contract — the dispatcher from
`domain/shell.dart`, its sentinel, a stop that is `SIGINT` to the group and a
`SIGKILL` a second later, the shell that comes back cold after an `exit` — and
is tested against it on the VM: `test/data/web/guest_shell_test.dart` plays
the guest with this machine's own processes behind the real frames. The first
command of a page boots the guest, which is most of a minute; the run's live
output says so while it does, and the command's timeout starts once there is
a shell to run it in.

### The app's files, mounted

The guest mounts the app's own files over 9p at the data directory's own path,
`/entoli`, served from `guest_files.dart` — a 9P2000.L server over the app's
`FileSystem`, which here is IndexedDB. Nothing is copied: a file the agent
writes with the `write` tool is the file `cat` reads in the next command, a
file `git` writes is the file the workspace explorer lists, and a path is the
same string to both, so `GuestShell` masks nothing (`guestRoot` is null) and
the file tools translate nothing. `HOME` is the project workspace, as in every
guest.

What the mount shows is a policy, `entoliGuestAccess`: every project's
`workspace/` read-write, its `skills/`, `skills-bundled/` and `agents/`
read-only (a skill's scripts run from where they are), and nothing else at
all — not `chats/`, not `settings.json`, not the secret store. A hidden path
is not there to a walk or a listing; it is not a permission error waiting to
be probed.

Three things IndexedDB does not have, and what stands in for each:

- **Permission bits.** Kept in `<dataDir>/guest-modes.json`, outside the mount,
  so a script made executable stays so across reloads and git does not see
  every file it wrote change mode.
- **A read of a file the app has since rewritten.** The guest mounts with
  `cache=mmap` — no page cache of its own, since the app writes these files
  between commands, but `mmap` for git's packs — and a read through a handle
  fs_shim keeps would still see the old length, so a read-only fid reads
  afresh each time.
- **Handles that survive a rename.** fs_shim's handle is to the path it was
  opened at, so every open file under a path is closed before the path moves
  or goes, and reopened at its new one on the next read or write.

Hard links, device nodes and extended attributes are refused. A lock is
always granted: there is one guest.

### Licences

The image is redistributed work: v86 (BSD-2-Clause), SeaBIOS (LGPL-3.0) and
Alpine's packages under their own licences. `build.sh` writes `NOTICE.txt`
and `packages.txt` beside them — every package and version, with where its
source is — which is what redistributing GPL binaries owes.
