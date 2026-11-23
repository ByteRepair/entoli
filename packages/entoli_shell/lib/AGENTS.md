# The shells

`entoli_shell` is where commands run: this machine's shell under Landlock or
Seatbelt, the downloaded Linux under proot, the iSH emulator on iOS, the tools
the APK ships, and the read-only modes and tree deletes they need. It implements
the core's `Shell`, `ShellDriver`, `SandboxHelper`, `SandboxFolders` and
`RootfsStore`, and the CLI providers' `CliGuest`, the place their program runs.
`entoli_shell.dart` is the one entry point: `platformShell`, `platformDriver`,
`cliGuestOf`, `openRootfsStore` and the rest, each a function of what the app
holds (settings, the data and cache directories, the download). The app binds
them in `lib/core/platform/host.dart`.

The iSH XCFramework and the Android binaries are the app's native build (`ios/`,
`android/`, `tool/`); the Dart here finds them by name
(`DynamicLibrary.process()`, the `agent_chat/tools` channel).

## Running the commands

The shell's contract, `bash`, background jobs and the user's `!` are the core's:
see `packages/entoli_core/lib/agent/AGENTS.md`.

`Shell.canRunCommands` is what a machine with no shell changes, and it is not
one failing command — it is the whole loop. With no shell there is nothing to
run, so `bashTool` is dropped from the request and a system prompt with no tool
instructions is used; the turn ends when the model replies with text and no tool
call, the same termination signal the shell path uses.

**What the commands run under is a `ShellDriver`, and which one is resolved
rather than named.** The host driver is the machine's own shell — `bash` then
`sh` off `PATH`, then `/bin/bash`, `/system/bin/sh`, `/bin/sh`, the two places a
shell sits that a `PATH` may not name, a stripped environment and Android, which
has no `/bin` at all. It was `/bin/bash` or `/bin/sh`, which meant a phone was
offered the `bash` tool and then failed every command it ran, one at a time.
Nothing found is a null driver and `canRunCommands: false`, which is the honest
answer: the loop stops offering a tool there is nothing behind. The other driver
is the guest — see "A whole Linux under proot" below — and `platformDriver`
picks between the two per command. **Android gets the guest or nothing.** Its
own shell was offered as "Host" until the Linux became what everything leans on
— package installs, Byte Repair's setup, the CLI programs — and a turn run on
toybox with no `/bin` only failed further in. With no Linux picked,
`platformDriver` is null there, as iOS's shell is with none installed,
`LocalShell.withoutDriver` tells the model why, and the first-run setup is what
installs one. `LocalShell` runs whichever it is handed, since to it both are a
command that ends in a shell, and that is the whole of what a new driver owes
it.

On Windows the host driver wants `bash.exe` or `sh.exe` off `PATH`, skipping
anything under `%SystemRoot%` — WSL's `System32\bash.exe` runs a Linux that
cannot take a Windows path — then Git for Windows' bash, found under
`%ProgramFiles%\Git` or beside the `git.exe` on `PATH`. There is no `setsid` and
no signal there: a stop or a timeout is `taskkill /T /F`, the one way to take
bash's children with it, and the interrupt step is skipped. The AppImage
runtime's `APPIMAGE`, `APPDIR`, `ARGV0` and `OWD` are stripped from every
command's environment; they describe the app, not the machine.

**The shell creates the directory it is told to stand in if it is not there.** A
spawn `workingDirectory` that does not exist fails with an ENOENT that names
neither the directory nor the reason, and the cwds the app hands the shell are
its own laid-out paths that may legitimately be missing: a project workspace
before its first chat — a built-in project's setup runs in one — or one a user
deleted from the Files app. So `_spawnInGroup` makes it before `Process.start`,
in the one place both the one-shot and the persistent paths spawn through.

**The commands run in one shell per chat, and its state is machine state the
conversation builds on.** A fresh subshell per command made a `cd` or an
`export` a private joke: the model moved the shell in one command, and the next
command was back in the workspace having heard nothing. So a chat has one
non-interactive shell — the agent's `bash` and the user's `!` share it, and it
is keyed by the chat's own workspace, which is unique to the chat — and what one
command did to the directory or the environment stands for the next.

Each command crosses as one base64 line on the shell's stdin: the raw script
never touches the wire, so a multi-line command, a quote or a `read` in it
cannot steal the next line of the queue. The dispatcher decodes the line and
evaluates it **in the shell itself** — a subshell would undo the point — and
then prints a sentinel naming the command's exit code and the directory the
shell is now in. The sentinel carries a token unique to the shell's life, so a
command's output cannot forge the end of a run, and the run completes on the
sentinel rather than on the pipe closing. That is the answer to the old hazard:
a child in a session of its own — a daemon started with `setsid`, anything a
`nohup` left behind — holds the pipe open after the shell is gone, and held it
open forever, so a run waited on the pipe was a turn nothing could finish. The
sentinel makes the run end when the command does; what the escaped child can
still delay is the settling of a run whose shell _died_, and that is bounded by
a grace on the process's exit rather than waited on.

Stopping a command is a `SIGINT` to the process group — a Ctrl-C, not a murder —
and a non-interactive shell dies on that signal unless it is told otherwise,
which is load-bearing: the dispatcher traps the interrupt so the shell waits for
the interrupted command to go, reports its 130, and keeps whatever state it had.
A trap on `EXIT` is the other end: a command that runs `exit` takes the shell
down with it, and the trap is what says how it went — the code and the directory
— before the pipe closes. A stop the command ignores is wedging the shell, and a
grace past it kills the group for real, the shell coming back cold on the next
command. A timeout escalates whichever way: what a non-interactive shell starts
in the background ignores the interrupt, and a timed-out `npm install` that only
lost its shell keeps downloading — so the kill lands the moment the command's
own sentinel comes, the interrupt spent and the grace unable to reach any
sooner, or at the end of the grace where the command never answered at all. The
group is the reason the shell is spawned under `setsid` where that exists —
learned by trying it, not by probing first.

**The command's label is the model's own word for it.** `bash` takes an optional
`description`, five to ten words on what the command does, and the reply draws
it as the row's label in place of "Used tool: bash" — Claude Code's design: no
second model reads the command to name it, so the label costs nothing. It is the
agent's claim about its command and nothing checks it. It is shown beside the
command, never in its place: the approval banner draws it above the command
(`approvalPurpose`), so the user sees the intent and what will run, and the
classifier reads it labelled as the agent's claim, judging the command and
asking where the two disagree. A call without one, and the user's `!`, keep the
tool's name.

**How long a command may run is Claude Code's two minutes and ten.**
`BuiltinOptions.commandTimeout` is what a call naming no `timeout` gets, two
minutes, and `maxCommandTimeout` is the most one may name, ten — Claude Code's
120,000 and 600,000 milliseconds, measured. It was three minutes for both, and
the chat that prompted the change had 25 commands hit it, mostly builds and CI
waits. The user's `!` gets the ten: they typed it and are there to stop it.

A command killed at its timeout keeps what it printed — the session shell's
interrupt and the one-shot kill both hand back the output so far — and
`ShellResult.timedOut` says that is why it stopped. Here Claude Code and this
part ways on purpose: Claude Code moves a timed-out command to the background
and lets it run, reporting
`Command did not complete within its 120s timeout and was moved to the background (ID: …)`.
Every Claude Code command is a process of its own, so stopping waiting is free;
here a chat's commands run in one shell, and a command left running in it is one
every later command waits behind. So it is killed, as before, and `bash` adds to
a timed-out result, where background jobs are offered, that something that long
goes in again with `background: true`. The descriptions say it ahead:
`command`'s that the whole output comes back and is saved past the limit, so
`| tail` buys nothing and a pipeline killed at the timeout loses all `tail` was
holding — 14 of that chat's 21 empty timeouts were pipes into `tail` or `head` —
and `timeout`'s and `background`'s that anything that may outlast the timeout is
a job.

A command that moved the shell records the directory it left it in, on the
result as a fact, and the projection words the change into a note the model
reads — the note is derived at wording time from the fact the part carries, not
baked into the output, so a reload words what the live turn did and the output
stays what the command printed. It tracks the directory across the turn's
commands and notes a move once it has been told where the shell is standing; the
turn's opening move is un-noted, the model having run the `cd` itself. The
composer's bar watches the same directory live while a `!` command is being
typed, and a tap copies it out.

What a shell is spawned with — its command and environment — is fingerprinted,
and a change respawns the shell cold: a variable added in settings, or a Linux
installed or deleted, reaches the next command rather than the next launch.

**A sandboxed command still moves the chat.** Under the sandbox every command is
a confined subshell of its own (see "Approvals" in
`packages/entoli_core/lib/agent/AGENTS.md`), so it cannot stand in the session
shell — and it used to start in the workspace whatever the session shell had
been moved to, which gave a chat two working directories, the model told of one
and standing in the other half the time. So `LocalShell` keeps one directory per
chat on the host (`standingIn`): a confined run starts there and ends by
printing where it finished after a marker unique to the run, cut from the output
and reported as the result's `ShellResult.cwd`, the same field the session
shell's sentinel fills; the session shell's sentinel updates the same place; and
the session shell `cd`s to it before a command when a confined run moved the
chat since. Exports, aliases and functions stay each confined run's own, which
is what the tool description says. A restart or a shell that died puts the chat
back in the workspace. A guest keeps none of this: its `pwd` is a guest path and
it has no confined subshell.

Sub-agents run `oneShot` instead: a fresh subshell per command, no state, no
sharing. A fan-out of workers wants concurrency rather than a terminal, and a
shell they all `cd` around is as many races as there are of them. The flag
reaches the shell and the prompt and the tool description together, so the model
is not told a state it cannot keep.

**The output a running command is printing is visible while it prints.** A
`ShellRun` carries an output listener beside its result, and the agent watches
it where a callback is handed to it, reporting each change at `watchInterval`'s
pace — a hundred milliseconds, the last value inside an interval being the one
sent, since what the block shows is the tail as it is now. What it reports is a
tail of the output, newlines kept, never the sentinel: the dispatcher's marker
can arrive split across chunks, so anything from the last place `\n@@E` could be
forming is held out of the live view until the next chunk proves it was ordinary
output. The final result is unchanged — the whole output, sentinel stripped —
and the block on screen is gone the moment the pair completes, the conversation
keeping only the pair. Nothing here is persisted and a sub-agent's commands are
not watched, the callback being null where the agent is one.

## Bundled tools

What `/system/bin/sh` gets you is toybox: `ls`, `cat`, `grep`, `sed`, `find`,
`tar` and about a hundred and fifty more — and no `git`, which for a coding
agent is most of what is missing.

The app used to ship one, cross-compiled against bionic beside a curl and an
OpenSSL that existed only to give it https. It no longer does. **git comes from
the rootfs now**: `apk add git` inside Alpine is one command, and a
distribution's own package is patched for a CVE by someone whose job that is,
where the three built here were ours to notice and rebuild and then ship as an
update every user had to install. What that costs is honest and worth stating —
on a device with no rootfs installed there is no git at all, and the agent is
back to toybox. See "A whole Linux under proot".

So what rides inside the APK is proot and llama.cpp's server, and `BundledTools`
lays them out at startup; nothing else about the shell changes, since the
workspace, the `cwd` and `LocalShell` are all where they already were.

**They live in the native library directory because it is the only place an app
may execute a file from.** Since Android 10, SELinux denies an app targeting API
29 or higher `exec` on anything under its own data directory — the W^X rule that
kept Termux pinned at `targetSdk` 28 and off Play. The library directory is not
that, so a binary there runs. Two details follow from it and both are
load-bearing: the files must be named `lib*.so`, since that is all the installer
extracts out of an APK, and `useLegacyPackaging` has to be on or they are mapped
from inside the APK and there is no file to run at all. That last one is
APK-wide — AGP has no per-library lever — so every other native library, the
Flutter engine included, is stored compressed and unpacked at install time as
well. The APK shrinks and the installed app grows by what was previously read
straight out of it.

`<cacheDir>/tools` is a tree of **symlinks** into that directory rather than
copies. A copy would be another twelve megabytes, and — being in app storage —
one nothing may execute; the link is followed at exec time, so what the kernel
sees is the file where it is allowed to be. They are repointed on every install
rather than kept, because the library path carries an install-specific segment
and every link from before an update points at nothing.

The cache directory rather than the data one, for the reason the voice models
are there: the app's `backup.dart` zips the data directory whole, and a backup
carrying a tree of links into an install that no longer exists is worse than
useless. On Android that is the support directory and so is not evictable — see
"Where the models live".

The environment is the rest of it, and with git gone it is `TMPDIR` and little
else. It rides in the host `ShellDriver` — the value that says what a command
runs under, and the one `LocalShell` layers its defaults and the settings over —
so the one place that decides what a command runs under decides this too, and
settings still win over all of it: a variable the user set is the one that
reaches the command.

**What was laid out and what the model is told about it are one value**, the
`Toolset` `install` answers with. `names` is what the system prompt says is
there, and it is null now that nothing is laid out by name — a build that
bundles a command again sets it, and the prompt follows without a second place
to remember. The rule reads the other way too, which is the harder half: taking
a tool away has to reach the prompt in the same breath, or the model finds out
one `command not found` at a time. That is why `platformDescription` says on
Android that there is no git and where one comes from.

**The toolset is frozen at build time**, and what is bundled is the whole of
what can be run directly: nothing downloaded may be executed, so there is no
package manager here and cannot be one. What lifts that is not another binary
but proot, and a whole Linux behind it — see "A whole Linux under proot" below,
which is where a package manager actually comes from.

Building them is `tool/android/`: `versions.sh` pins what is built and its
checksums, `build.sh` cross-compiles talloc and then proot against it, and
llama.cpp's server for arm64, `stage.sh` puts the result where the APK packages
it from. The output needs nothing but `libz`, `libdl` and `libc`, all of which
Android already ships, and `build.sh` checks that against the NDK's sysroot
rather than leaving the phone to say so. None of it is checked in: CI builds it
through `.github/actions/bundled-tools`, cached on the recipe and the versions,
and the release build refuses an APK that came out without proot in it.

Nothing being checked in is also why a locally built APK is the one that ships
without them: a `dist/` from an older run stages what it has and no more, and
`jniLibs/` is ignored, so the gap shows up on a phone rather than in a diff.
Missing proot then reads as the Terminal page having lost its catalog, which is
drawn from the same answer. **So the page says which it is**: an ABI that
Android answered with and no proot beside it is a build fault, and it names the
two commands that fix it rather than describing a device that cannot run a
Linux. Only whoever built the APK can reach that, since the release build
refuses one with no proot in it.

Everything here is also **ours to update**: nothing on the device does it for
us, so a CVE in a bundled tool is a version bump in `versions.sh` and a release
every user has to install. That is the cost that took git out of this list, and
it is worth weighing before anything is added back to it.

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

**One patch, and it is ours: `--read-only`.** `-0` fakes root by handing the
owner read and write on every path the guest touches, for the length of the
syscall (`fake_id0`'s `HOST_PATH` hook), and the owner may `chmod` its own files
whatever their mode. Between them the read-only directories (see "Read- only
directories" in the root notes) were writable in the guest as if nothing had
locked them. `tool/android/patches/proot-read-only.patch`, applied by
`build.sh`, adds `--read-only PATH`: the hook skips anything under PATH, so the
kernel's refusal reaches the guest, and a small extension refuses `chmod`,
`fchmod` and `fchmodat` there with `EROFS`. The driver passes it for each of
`Shell.start`'s `readOnly` — the chat's `resources/` and the skills and agents
directories, one list the backend builds for every shell — binding at its own
host path whatever it has not bound at a clean one already. Checked on a host
build of the same tree: without the flag a guest root overwrote, deleted,
renamed and `chmod`ed a `0444` file in a `0555` directory; with it, each was
refused and reads still worked.

**The distribution is Alpine, and one version of it.** The core's
`model/rootfs.dart` is the catalog, const data like the voice models. Alpine is
4 MB against Debian's 120, it is an official tarball rather than somebody's
build of one, it is `.tar.gz` where the alternatives are `.tar.xz` — which a
phone's `tar` cannot pipe and Dart decodes at a crawl — and `apk` is a package
manager from the first command. What it is not is glibc, so a prebuilt binary
someone downloads may refuse to run; a second entry here is what would answer
that.

**The tarball's checksum is pinned and checked before anything is unpacked.**
Everything in there becomes a program this device will execute, so arriving is
not the same as being what was checked — the bargain `tool/android/versions.sh`
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
reason the voice models are: the app's `backup.dart` zips that directory whole,
and a restore _replaces_ it. A `.complete` marker written last is the whole of
what "installed" means.

**The project workspace is bound into the guest at `/root`, not the data
directory at its own Android path.** The model sees `~` for the project
workspace and `~/chats/<id>` for the chat's own, not the full `/data/user/0/...`
path. The rest of the device is not there. Skills are bound at
`/opt/skills-bundled` and `/opt/skills` so their scripts are reachable, with a
project's own two skills dirs beside them at `/opt/skills-bundled-project` and
`/opt/skills-project` — and only where each directory exists on disk, proot
refusing a binding to a path that is not there (`platformDriver` drops one at
resolution, which is asked per command). The file tools translate `~` and guest
paths back to the host's, since they use the host filesystem.
`ShellDriver.commandFor` builds the proot invocation per chat, because the bind
mounts and `-w` need the chat's own `cwd` and `home`. The `-w` flag takes the
guest path of the chat workspace (e.g. `/root/chats/<id>`), not `.` — proot
stores `-w` as the guest cwd, and `.` resolves against the guest root, not the
host's working directory.

**proot creates mode-0000 stubs at its bind targets, and they are why
`tree_ops.dart` exists.** Where a bind's guest path does not exist in the rootfs
— the four `/opt/skills*` paths and `/etc/resolv.conf` are what this app's binds
produce, since the Alpine tarball has none of them — proot creates an
inaccessible placeholder to mount over. In the guest the stub is invisible; on
the host it is poison, because `dart:io` cannot list a mode-0000 directory, so a
recursive delete over a rootfs that hosted a session dies on one and a `cp` that
has to read one does too — both were live on a device. The selected rootfs is
shared across projects, so setup does not copy it. Terminal rootfs deletion
still goes through `removeTree`, which `chmod -R u+rwX`es first because a guest
`chmod` is a real one on the host and may have closed directories that have to
be reopened to be deleted.

**`HOME` inside the guest is the project's workspace, not `/root`.** The rootfs
is one directory shared by every project and outside what a backup carries, so a
`~/.gitconfig`, an `npm` cache or a key written there belongs to whichever chat
wrote it last and is gone on a reinstall. The project workspace is the
project's, is backed up, and is the directory the chat's own working directory
sits in — so `cd ~` from a turn reaches the workspace the model is already told
to leave work in, and one project is one environment. What it costs is that
dotfiles and tool caches are among the project's files: the workspace explorer
lists them and a backup carries them.

Per project rather than per chat because that is what an environment is for — a
clone or an installed package is worth having in the next conversation, and a
per-chat `HOME` would fetch it again every time.

It is `LocalShell` that sets it, from the `home` its caller passes beside `cwd`:
the driver says whose home a command's is and cannot know which project is
running. Only where it says so — a guest, or Android, where the machine's own
home is a shared app user's — a desktop's `HOME` is the user's own and the tools
there expect what is in it.

**The guest driver's environment is the whole of its base.** Every path the host
toolset names is the host's, and a `TMPDIR` under the app's own directory is not
where a guest's `/tmp` is. That used to be a rule a sandbox kept — replacing the
toolset rather than layering over it — and is now the shape: a driver carries
its own environment, and there is no host one beside it to replace. Settings
still win over it, which is the rule that was already there.

**Which one commands run in is read per command**, through the same seam
`LocalShell` re-reads `environment` through, so installing a Linux or going back
to Android reaches the next command rather than the next launch. That is why
`platformDriver` is synchronous and `RootfsStore` has a `directoryOfSync`: it is
asked before every command, and on this side of the app that is one `stat`.

**Android keeps no `/etc/resolv.conf`**, and a guest program reads nothing else
to find a resolver. So `BundledTools` writes one — from what
`ConnectivityManager` says the current network uses, which is the user's own DNS
rather than a public resolver picked here on their behalf, and the only reason
the app asks for `ACCESS_NETWORK_STATE`. It is written at every launch and bound
over the guest's copy, so it is one file whatever is installed and it follows
the network the device is actually on rather than the one it was on the day the
rootfs was downloaded. Android saying nothing writes nothing: a guest that
cannot resolve a name is honest, where a silent fallback to someone else's
resolver is not.

The invocation itself is `proot.dart`: `prootDriver`, a pure function so that
the whole of what this feature does can be pinned by a test on a machine with no
Android on it. What it answers is the guest's `ShellDriver`, and the machine's
own shell is the host driver, the other one: `LocalShell` runs whichever it is
handed, and to it a guest is only a longer command that ends in a shell.
`--kill-on-exit` because a killed tracer otherwise leaves its tracees running;
`--link2symlink` because a package manager unpacks with hard links and app
storage may not have them; `-0` because `apk` wants to be root, which is a lie
told to the guest rather than a privilege — the process is still the app's own
uid to the kernel.

What it costs is worth knowing: proot is ptrace-based, so filesystem-heavy work
is noticeably slower than native, which is why the guest driver's description
tells the model so. What it does not cost is size — 300 KB an ABI, against git's
12 MB, and the rootfs is downloaded rather than shipped.

Building it is `build.sh` again, beside git. proot is termux's fork rather than
proot-me's, for the Android work already in it, and its one dependency is
talloc, which is built **from `talloc.c` alone** against `talloc-config.h` — the
answers talloc's own build system would have worked out by running test
programs, which it cannot do when cross-compiling. That is why there is no waf
step here and why the result is one object file. Two adjustments to proot, and
only two: an `#include <string.h>` upstream leaves out, which clang now refuses
rather than warns about, and `PROOT_UNBUNDLE_LOADER`, which keeps the loader a
file of its own instead of one extracted to app storage and exec'd — the thing
that cannot work here.
