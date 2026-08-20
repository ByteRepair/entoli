# What the shell can reach

## Bundled tools

What `/system/bin/sh` gets you is toybox: `ls`, `cat`, `grep`, `sed`, `find`,
`tar` and about a hundred and fifty more — and no `git`, which for a coding
agent is most of what is missing. So the app ships one. `git` and
`git-remote-http` are built against bionic with the NDK and ride inside the
APK, and `BundledTools` lays them out at startup; nothing else about the shell
changes, since the workspace, the `cwd` and `LocalShell` are all where they
already were.

**They live in the native library directory because it is the only place an
app may execute a file from.** Since Android 10, SELinux denies an app
targeting API 29 or higher `exec` on anything under its own data directory —
the W^X rule that kept Termux pinned at `targetSdk` 28 and off Play. The
library directory is not that, so a binary there runs. Two details follow from
it and both are load-bearing: the files must be named `lib*.so`, since that is
all the installer extracts out of an APK, and `useLegacyPackaging` has to be on
or they are mapped from inside the APK and there is no file to run at all. That
last one is APK-wide — AGP has no per-library lever — so every other native
library, the Flutter engine included, is stored compressed and unpacked at
install time as well. The APK shrinks and the installed app grows by what was
previously read straight out of it.

`<cacheDir>/tools` is a tree of **symlinks** into that directory rather than
copies. A copy would be another twelve megabytes, and — being in app storage —
one nothing may execute; the link is followed at exec time, so what the kernel
sees is the file where it is allowed to be. They are repointed on every install
rather than kept, because the library path carries an install-specific segment
and every link from before an update points at nothing.

The cache directory rather than the data one, for the reason the voice models
are there: `backup.dart` zips the data directory whole, and a backup carrying a
tree of links into an install that no longer exists is worse than useless. On
Android that is the support directory and so is not evictable — see "Where the
models live".

The environment is the rest of it: `PATH` with the system's own commands behind
ours, `GIT_EXEC_PATH` (git resolves `git-remote-https` and friends by name, so
the one helper is linked under each scheme it might be asked for), `HOME`,
`TMPDIR`, and `SSL_CERT_DIR` pointed at Android's own trust store, which is a
directory of hashed certificates rather than a bundle file. It is layered in
`LocalShell` beside the defaults that were already there, so the one place that
decides what a command runs under decides this too, and settings still win over
all of it — a variable the user set is the one that reaches the command.

**What was laid out and what the model is told about it are one value**, the
`Toolset` `install` answers with. They were a return value and a mutable global
next to it, which is an ordering nothing in the types insisted on: get it wrong
and git is on the `PATH` while the prompt never mentions it, which is the silent
half-failure this file keeps arguing against elsewhere.

**The toolset is frozen at build time**, and what is bundled is the whole of
what can be run directly: nothing downloaded may be executed, so there is no
package manager here and cannot be one. What lifts that is not another binary
but proot, and a whole Linux behind it — see "A whole Linux under proot" below,
which is where a package manager actually comes from.

Building them is `tool/bundle/`: `versions.sh` pins what is built and its
checksums, `build.sh` cross-compiles OpenSSL and curl statically and then git
against them, `stage.sh` puts the result where the APK packages it from. Three
adjustments make git build for bionic, and only three — `NO_OPENSSL=1` (git
has its own SHA), `android-compat.h` for `pthread_setcancelstate`, which bionic
does not have at all, and dropping `-lpthread`/`-lrt`, which bionic folds into
libc. The output needs nothing but `libz`, `libdl` and `libc`, all of which
Android already ships. About 12 MB an ABI, which is why nothing here is checked
in: CI builds it through `.github/actions/bundled-tools`, cached on the recipe
and the versions, and the release build refuses an APK that came out without
git in it.

That also means git, curl and OpenSSL are **ours to update**: nothing on the
device does it for us, so a CVE in any of them is a version bump in
`versions.sh` and a release.

## A whole Linux under proot

A bundled binary is one binary. What a coding agent actually wants is a package
manager, and on Android that is the thing W^X takes away: since API 29 SELinux
denies an app `exec` on anything under its own data directory, so nothing
downloaded can ever be run. Termux stayed at `targetSdk` 28 for years over
exactly this, and lowering ours is not on the table — the three foreground
services are written against the typed model and `POST_NOTIFICATIONS`, all of
which is 33-and-later behaviour.

**proot gets past it by not exec'ing anything.** On intercepting `execve` it
substitutes its own loader for the program, and that loader maps the guest
binary and its ELF interpreter itself. Mapping is the permission W^X leaves
granted; exec is the one it takes away. The single file that really is exec'd is
the loader, and `get_loader_path()` reads `PROOT_LOADER` before anything else —
so shipping proot and its loader as `lib*.so` in the native library directory,
which is where "Bundled tools" above already puts executables, is the whole of
the fix. Nothing is patched to make that true.

**The distribution is Alpine, and one version of it.** `domain/rootfs.dart` is
the catalog, const data like the voice models. Alpine is 4 MB against Debian's
120, it is an official tarball rather than somebody's build of one, it is
`.tar.gz` where the alternatives are `.tar.xz` — which a phone's `tar` cannot
pipe and Dart decodes at a crawl — and `apk` is a package manager from the first
command. What it is not is glibc, so a prebuilt binary someone downloads may
refuse to run; a second entry here is what would answer that.

**The tarball's checksum is pinned and checked before anything is unpacked.**
Everything in there becomes a program this device will execute, so arriving is
not the same as being what was checked — the bargain `tool/bundle/versions.sh`
already makes for what is built into the APK. Bumping Alpine is a line in the
catalog.

**The system's `tar` unpacks it, not `package:archive`.** A rootfs is symlinks,
execute bits and the odd hard link — `/bin/ls` is a link to busybox, and a
busybox with no execute bit is a Linux that cannot run its first command — and
Dart can write none of the three, having no `chmod` at all. `tar -xzf` gets all
three right and is faster besides. It is injected into `FileRootfsStore` so a
test can watch what it was asked to do, and the real one is tried on `PATH`
before `/system/bin/tar`, the two-step `LocalShell` already takes to find a
shell.

Where it lives is `<cacheDir>/rootfs/`, outside the data directory, for the
reason the voice models are: `backup.dart` zips that directory whole, and a
restore *replaces* it. A `.complete` marker written last is the whole of what
"installed" means.

**The data directory is bound into the guest at its own path.** Not a tidier
`/workspace`: every path the app has ever handed the model — the chat's
workspace, the project's, an artifact — then means the same thing inside the
guest as outside it, the host `cwd` and proot's `-w` are the same string, and
nothing else in the app has to learn that commands are running somewhere else.
The workspace explorer, the `DocumentsProvider` and a resend of an old turn all
keep working with no knowledge of any of this.

**A `Sandbox` replaces the `Toolset` rather than layering over it.** Inside the
guest the bundled bionic git is the wrong answer and `GIT_EXEC_PATH` names a
host directory that is not there; `apk add git` is the right one. So the guest
gets the guest's `PATH` and nothing of the host's — and settings still win over
both, which is the rule that was already there.

**Which one commands run in is read per command**, through the same seam
`LocalShell` re-reads `environment` through, so installing a Linux or going back
to Android reaches the next command rather than the next launch. That is why
`platformSandbox` is synchronous and `RootfsStore` has a `directoryOfSync`: it
is asked before every command, and on this side of the app that is one `stat`.

**Android keeps no `/etc/resolv.conf`**, and a guest program reads nothing else
to find a resolver. So `BundledTools` writes one — from what `ConnectivityManager`
says the current network uses, which is the user's own DNS rather than a public
resolver picked here on their behalf, and the only reason the app asks for
`ACCESS_NETWORK_STATE`. It is written at every launch and bound over the guest's
copy, so it is one file whatever is installed and it follows the network the
device is actually on rather than the one it was on the day the rootfs was
downloaded. Android saying nothing writes nothing: a guest that cannot resolve a
name is honest, where a silent fallback to someone else's resolver is not.

The invocation itself is `data/local/proot.dart`, a pure function so that the
whole of what this feature does can be pinned by a test on a machine with no
Android on it. `--kill-on-exit` because a killed tracer otherwise leaves its
tracees running; `--link2symlink` because a package manager unpacks with hard
links and app storage may not have them; `-0` because `apk` wants to be root,
which is a lie told to the guest rather than a privilege — the process is still
the app's own uid to the kernel.

What it costs is worth knowing: proot is ptrace-based, so filesystem-heavy work
is noticeably slower than native, which is why `platformDescription` tells the
model so. What it does not cost is size — 300 KB an ABI, against git's 12 MB,
and the rootfs is downloaded rather than shipped.

Building it is `build.sh` again, beside git. proot is termux's fork rather than
proot-me's, for the Android work already in it, and its one dependency is
talloc, which is built **from `talloc.c` alone** against `talloc-config.h` —
the answers talloc's own build system would have worked out by running test
programs, which it cannot do when cross-compiling. That is why there is no waf
step here and why the result is one object file. Two adjustments to proot, and
only two: an `#include <string.h>` upstream leaves out, which clang now refuses
rather than warns about, and `PROOT_UNBUNDLE_LOADER`, which keeps the loader a
file of its own instead of one extracted to app storage and exec'd — the thing
that cannot work here.
