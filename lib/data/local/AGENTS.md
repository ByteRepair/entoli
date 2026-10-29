# What the shell can reach

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

The environment is the rest of it, and with git gone it is `TMPDIR` and little
else. It rides in the host `ShellDriver` — the value that says what a command
runs under, and the one `LocalShell` layers its defaults and the settings over
— so the one place that decides what a command runs under decides this too,
and settings still win over all of it: a variable the user set is the one that
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

## Byte Repair's environment, in four variables

`byte-repair-setup.sh` answers to what it is told and probes nothing. Where to
install is the store's `ENV_INSTALL_DIR` — `/usr/local/bin` inside a guest
(both of them: Android's proot rootfs and iOS's iSH Alpine), the app's own
`<cacheDir>/byte-repair/bin` on every desktop — and the script exits
rather than guess a destination. What installs packages is
`ENV_PACKAGE_MANAGER` — `apk` in a guest, from the same `Rootfs.packageManager`
the proot guest driver declares for every command in it, and what the install
environment names for the setup run — `brew` on a mac, and nothing on the
Linux and Windows hosts, whose package managers are not ours to touch. Unset
does not mean unavailable: a skipped install is a note and the run carries on,
so a host with make already on it pays nothing and one without it sees the
honest "Not installed" row. A named manager that fails is a failure, so a guest
install that did not happen never reads as done, and one the script does not
know is refused before anything runs. Only `apk` and `brew` are ever named;
the arms for apt-get, dnf, yum and pacman went, being code nothing reached.

**Install what is missing, touch nothing else.** A guest gets `apk add
--no-cache` of exactly the missing packages — no `apk update` (the
`--no-cache` add fetches the index itself) and no `apk upgrade`, which
upgraded the whole guest on every setup, iSH's one base Alpine every project
shares included. Brew is told the same with `HOMEBREW_NO_INSTALL_UPGRADE`
and `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`, without which `brew install`
upgrades a formula the user already has and then upgrades or reinstalls what
depends on whatever it upgraded; `HOMEBREW_NO_INSTALL_CLEANUP` keeps the old
versions the user's own builds may still link. A dependency esbmc needs newer
than the installed one is still upgraded, since there is no install without
it.

**A mac installs with Homebrew because nothing else starts there.** ESBMC's
macOS release is linked against Homebrew's z3, mpfr, gmp, boost and llvm by
absolute path and ships none of them, so on a mac without exactly those kegs
the fetched binary died in the loader and the setup could never succeed.
The formula is bottled and brings its own dependencies, so the store names
`brew` on a mac host, and the fourth variable, `ENV_BREW`, is the `brew` it
found at Homebrew's two supported prefixes (`/opt/homebrew`, `/usr/local`) —
the store asks, the script is told. What brew installs, make and gh included,
lives in Homebrew's prefix, outside the app, and is *linked* into the bin
directory rather than copied: a `brew upgrade` moves the kegs a binary loads,
and a link follows the formula where a copy would be left pointing at the old
ones. Homebrew's make is `gmake` on PATH, so the link is to its `gnubin` make.
Every link is run before the setup carries on, so one pointing at nothing is a
failure rather than a "Not installed" row after a setup that said it worked.
A delete takes the links and leaves Homebrew's installs, and the settings page
says before Run Setup that the tools go into the system rather than the app.

Homebrew itself is not installed by the setup. Its installer asks for an
administrator's password through sudo, which a run with no terminal cannot
type, and its `NONINTERACTIVE` mode — the installer's variable, not
`brew`'s — aborts unless sudo is already cached. A
private Homebrew under the cache directory needs no sudo but is no answer
either: Homebrew's bottles relocate only to a prefix of a few characters, so
`llvm@22`, `boost`, `python@3.14` and `openssl@4` would build from source —
hours, and Xcode's tools. So with no `ENV_BREW` the script refuses, naming
brew.sh's install command, and the settings page shows the same command in a
code block with a copy button until a `brew` is there.

The one thing the script does probe is the platform it is on — `uname -s`,
which picks the ESBMC release the fetch lands, with `uname -m` splitting it on
Linux alone: esbmc-windows, and esbmc-linux for x86_64 or its armv8 brother
for arm64. The machine it runs on is the machine the binary runs on, so this
probe is honest. Anything else refuses before the download rather than after
it: a platform it does not know, a Linux arch with no release (a 32-bit
`armv7l` userland once got the x86_64 zip and an "Exec format error" 240 MB
later), and a mac told no package manager, whose release cannot start without
Homebrew's libraries. The name the release's binary carries
in is not probed at all — it is told (`ENV_ESBMC_BINARY`, the same
`esbmcFileName` the gate asks for and the import writes under, one encoding
of the name, Dart's), and the script's own default is the bare POSIX one.
Windows is the one of the three with no unzip of its own, where PowerShell's
Expand-Archive is the fallback the chain reaches. The binary's own `bin/`
lands whole, not one file out of it: the windows release carries `libz3.dll`
where its `esbmc.exe` is, and a single-binary move would leave an install
that cannot load its z3. The binary is the first file under a `bin/` named
for it, wherever the release nests that (v8.4 at the root, v8.5 under
`release/`).

The download and the extract happen in a scratch directory made fresh by
`mktemp` inside the bin directory, not at a fixed `/tmp` path. A fixed path
let an interrupted run's leftovers be read by the next one — its `find`
picking an older release's binary — let another user on a shared machine
plant one there first, and leaked the 240 MB zip on every failed attempt,
`set -e` leaving with no cleanup. An exit trap removes the scratch however the
run ends, a run killed outright leaves it for the next run to sweep before
it starts, and the final move is a rename on the one filesystem. Each step
that can fail without saying why — a download (`wget -q` prints nothing), an
extract — fails with a line naming it, the downloads give up on a stalled
connection after 30 seconds rather than at the half-hour limit, and `unzip
-q` keeps the archive's listing out of the text the settings page shows as
the error.

"Already installed" means *on PATH and runs* (`works`, a `--version` probe),
not merely found: a binary present but unstartable — a local build missing its
libraries — once read as installed, was skipped, and setup exited 0 having
done nothing. The PATH binary that probe found is copied into the bin
directory, so a setup that fetched nothing leaves the gate the file it asks
for. The run's tail verifies that file outright, not whatever PATH answers:
a bin directory holding an unstartable leftover behind a working machine
binary is the setup's failure to report — exit 1 and the settings page
showing the loader's error — where a fallback to PATH would have blessed
the stale install.

On every desktop the fetched tools reach their turns through the driver:
`platformDriver`
prefixes the bin directory onto `PATH` for rootfs-isolated projects alone, the
way the project's rootfs copy is its own — separated by `:` except on Windows,
whose is `;`. A user-set `PATH` in the command
environment still wins over it. The chat page's setup gate asks after the
binary itself on the host, since `<cacheDir>` can be emptied between setups —
the marker alone said a thing the cache may have since taken away. Inside a
guest the marker alone is enough, and on every guest platform the pick of a
rootfs is the gate itself — Android because the "Host" env has no package
manager, iOS because its "Host" is no shell at all. Two
consequences worth knowing: the script's in-script fetches (`releases/latest`
for gh and ESBMC) are the one deliberate exception to the checksum pinning
everywhere else in this app, because "Run Setup" is a button the user pressed
rather than a download the app decided on; and `ensureRootfs` is a no-op off
Android, where there is no guest for a per-project rootfs copy to serve — iOS's
iSH guest runs the base Alpine, so a setup's installs land in what every chat
on the device shares — so a `rootfsId` left over from another device does not
pay for a copy nothing reads. That iSH install is also no host tree of the
store's: import and the environment delete go by `installDir` naming the
guest const, never a host path to reach the fakefs with.

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
syscall (`fake_id0`'s `HOST_PATH` hook), and the owner may `chmod` its own
files whatever their mode. Between them the read-only directories (see "Read-
only directories" in the root notes) were writable in the guest as if nothing
had locked them. `tool/android/patches/proot-read-only.patch`, applied by
`build.sh`, adds `--read-only PATH`: the hook skips anything under PATH, so the
kernel's refusal reaches the guest, and a small extension refuses `chmod`,
`fchmod` and `fchmodat` there with `EROFS`. The driver passes it for each of
`Shell.start`'s `readOnly` — the chat's `resources/` and the skills and
agents directories, one list the backend builds for every shell — binding at its own
host path whatever it has not bound at a clean one already. Checked on a host build of the same tree: without the flag a guest root
overwrote, deleted, renamed and `chmod`ed a `0444` file in a `0555` directory;
with it, each was refused and reads still worked.

**The distribution is Alpine, and one version of it.** `domain/rootfs.dart` is
the catalog, const data like the voice models. Alpine is 4 MB against Debian's
120, it is an official tarball rather than somebody's build of one, it is
`.tar.gz` where the alternatives are `.tar.xz` — which a phone's `tar` cannot
pipe and Dart decodes at a crawl — and `apk` is a package manager from the first
command. What it is not is glibc, so a prebuilt binary someone downloads may
refuse to run; a second entry here is what would answer that.

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
reason the voice models are: `backup.dart` zips that directory whole, and a
restore *replaces* it. A `.complete` marker written last is the whole of what
"installed" means.

**The project workspace is bound into the guest at `/root`, not the data
directory at its own Android path.** The model sees `~` for the project
workspace and `~/chats/<id>` for the chat's own, not the full
`/data/user/0/...` path. The rest of the device is not there. Skills are bound
at `/opt/skills-bundled` and `/opt/skills` so their scripts are reachable, with
a project's own two skills dirs beside them at `/opt/skills-bundled-project`
and `/opt/skills-project` — and only where each directory exists on disk, proot
refusing a binding to a path that is not there (`platformDriver` drops one at
resolution, which is asked per command). The
file tools translate `~` and guest paths back to the host's, since they use the
host filesystem. `ShellDriver.commandFor` builds the proot invocation per chat,
because the bind mounts and `-w` need the chat's own `cwd` and `home`. The
`-w` flag takes the guest path of the chat workspace (e.g. `/root/chats/<id>`),
not `.` — proot stores `-w` as the guest cwd, and `.` resolves against the
guest root, not the host's working directory.

**proot creates mode-0000 stubs at its bind targets, and they are why
`tree_ops.dart` exists.** Where a bind's guest path does not exist in the
rootfs — the four `/opt/skills*` paths and `/etc/resolv.conf` are what this
app's binds produce, since the Alpine tarball has none of them — proot
creates an inaccessible placeholder to mount over. In the guest the stub is
invisible; on the host it is poison, because `dart:io` cannot list a mode-0000
directory, so a recursive delete over a rootfs that hosted a session dies on
one and a `cp` that has to read one does too — both were live on a device. So
the per-project rootfs copy (`FileByteRepairStore.ensureRootfs`) is a tar round
trip through `copyTree`, which excludes the stub paths (nothing there is
reachable in the guest anyway) and starts by clearing whatever an earlier
attempt left; and every rootfs deletion — the project's environment, and the
Terminal page's — goes through `removeTree`, which `chmod -R u+rwX`es first
because a guest `chmod` is a real one on the host and may have closed
directories that have to be reopened to be deleted.

**`HOME` inside the guest is the project's workspace, not `/root`.** The rootfs
is one directory shared by every project and outside what a backup carries, so a
`~/.gitconfig`, an `npm` cache or a key written there belongs to whichever chat
wrote it last and is gone on a reinstall. The project workspace is the project's,
is backed up, and is the directory the chat's own working directory sits in — so
`cd ~` from a turn reaches the workspace the model is already told to leave work
in, and one project is one environment. What it costs is that dotfiles and tool
caches are among the project's files: the workspace explorer lists them and a
backup carries them.

Per project rather than per chat because that is what an environment is for —
a clone or an installed package is worth having in the next conversation, and a
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
`platformDriver` is synchronous and `RootfsStore` has a `directoryOfSync`: it
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

The invocation itself is `data/local/proot.dart`: `prootDriver`, a pure
function so that the whole of what this feature does can be pinned by a test on
a machine with no Android on it. What it answers is the guest's `ShellDriver`,
and the machine's own shell is the host driver, the other one: `LocalShell`
runs whichever it is handed, and to it a guest is only a longer command that
ends in a shell. `--kill-on-exit` because a killed tracer otherwise leaves its
tracees running; `--link2symlink` because a package manager unpacks with hard
links and app storage may not have them; `-0` because `apk` wants to be root,
which is a lie told to the guest rather than a privilege — the process is still
the app's own uid to the kernel.

What it costs is worth knowing: proot is ptrace-based, so filesystem-heavy work
is noticeably slower than native, which is why the guest driver's description
tells the model so. What it does not cost is size — 300 KB an ABI, against
git's 12 MB, and the rootfs is downloaded rather than shipped.

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

## Running a model on the device

A model downloaded here answers with no network and no account. It is
llama.cpp's own server, bundled in the APK, started when a model is picked and
bound to the loopback address — and **it reaches the agent as an ordinary
provider**, because what it speaks is the `/chat/completions` shape
`OpenAiClient` was already written for. So `LlmRegistry`, the model picker, a
chat's pinned model, `meta.json`, the projection and every tool the agent has
work unchanged, and nothing below the settings page knows a model is local.

That is what rules out the alternative, which was binding libllama through FFI
and skipping the process. A small model's idea of a tool call is a template's
worth of prose that has to be parsed back into an OpenAI call, and doing that
per model family is most of what llama.cpp's server *is*. Writing a second copy
of it in Dart, to save a subprocess on a device that is about to spend a
gigabyte of memory on weights, is the wrong trade.

The endpoint is composed by `llmEndpoints` rather than written into
`settings.json`, and it has no address to write: each model is its own process
on a port asked of the OS when it loads. It goes **first** in the list, which is
what decides a collision — `localProviderId` is the app's name, and a
`settings.json` that happens to use it is shadowed rather than allowed to take
the models' own endpoint away from them. What is stored is how to run them —
`maxLocalModels`, `localModelDevice`, `localModelContext` — and never which one,
because that is not this page's to say.

### Loading one, and when

**Every model on disk is in the picker, and asking for one is what loads it.**
There is no model pick on the settings page and deliberately none: which model
answers is chosen where every other model is — the app default, a chat's own
settings, the title and classifier pickers. A pick here would have been a second
place to say the same thing and the one place that could disagree with the rest.
It also means a launch loads nothing at all, where it used to spend a minute and
a gigabyte restoring a pick the user might not have been about to use.

**`LocalLlm.serve` is the only thing that reconciles what is running with the
settings**, and there is no second path to forget. It answers from a server
already up under the same device and context, reloads one that is up under
different ones, and starts one that is not up at all. Settings ride in per call
rather than being held, the way `LocalShell` re-reads its environment, so a
change reaches the next turn — and pointedly not the current one, which keeps a
context edit from pulling the model out from under a chat mid-reply.

**Two may be resident, and `maxLocalModels` is what says so.** The pair is not
symmetric, which is the whole reason the setting is worth having: a 0.8B naming
chats beside a 4B answering them costs far less than the 4B twice. Past the cap
the least recently served is stopped first, and stopped *before* the new one
starts — overlapping them would put two sets of weights in memory at once, which
is the thing the cap exists to prevent. Two is the ceiling rather than a number
to type: each is a process holding its own weights and its own `kvBudgetBytes`,
and a phone that could hold three is not the phone this is written for. With the
cap at one and a title model set, the two evict each other every turn; that is
the honest cost of one, and the reason to raise it.

**The client is what routes**, not the registry. `LocalPoolClient` reads the
model out of the request, serves it, and hands the call to a `OpenAiClient` on
that server's port — one per model, dropped when the port changes, the same
signature check `LlmRegistry` makes. **It rides on the provider rather than on
the registry**: `OnDeviceProvider` is an `LlmProvider` whose `client` is the
pool, as `AppleFmProvider`'s is the framework's channel, so the registry never
compares a provider id against a reserved name — it knows nothing about who
its providers are. A
turn sent at a loading model waits; a turn sent at a model that will never load
gets the server's own last words as an `LlmException`, which for a model too
large to fit is the only place that is said at all.

The provider's `baseUrl` is empty, and that is not a placeholder standing in for
a real one — there is no single address for "on-device". Nothing reads it, since
the endpoint carries its own client, and an empty string keeps the registry's
cache signature still while servers come and go underneath it.

### How much context, and why it is per model

**`-c` is always passed.** llama.cpp's `--fit` would otherwise size it, and on a
phone that is wrong in a way it is not on a desktop: the CPU backend reports
`free` as every physical page (`ggml-cpu.cpp`, and it says so in a comment), so
the context would be fitted against the phone's whole RAM rather than against
what Android will let this app keep resident. A KV cache sized that way is an
app the low-memory killer takes.

**The default is the model's own**, `DownloadedModel.defaultContext`:
`kvBudgetBytes` divided by what one token of *that* model's KV cache costs,
rounded down to a power of two and never past what it was trained on. The cost
is K and V for every layer with attention heads, f16, read off the downloaded
file's own header (`data/local/gguf.dart`) rather than guessed from the
parameter count, which does not decide it — and rather than written into the
catalog, so a model added by link is sized the same way. `head_count_kv` is one
number for every layer or, in a hybrid such as LFM3, a list where a convolution
layer has none. LFM3 1.7B costs 22 KiB a token and Qwen3.5 4B 128 KiB, so the
same gigabyte buys 32,768 tokens on one and 8,192 on the other.

It matters more than it looks, because the agent's own prompt is not small: the
system prompt and the tool schemas are about 2,700 tokens before the user has
typed anything. The 4,096 this used to default to left roughly one exchange.

The Context setting overrides it for every model at once. That is the honest
shape now that any downloaded model can be the one a turn asks for — there is no
longer a single picked model for a per-model override to attach to.

### What is in the catalog, and what is downloaded

Two lists. The catalog (`localModelCatalog`) is what is offered: each entry a
download filled in ahead of time, one tap and no form. What is downloaded is
whatever is on disk, each directory with a record of what it is
(`DownloadedModel`, `model.json`) beside the weights, whatever it was fetched
from — a catalog entry, a link the user typed on the Add model page, or an entry
an older catalog offered. A model the catalog drops is therefore nothing to
migrate: it stays in the pickers and on the settings page, and runs, until it is
deleted. A directory from a build before records has its record written from
its own header the first time it is listed.

Three things have to be true before a catalog row can exist: the publisher of
the file has to ship **Q4_0** — see "What the NPU actually is" — the GGUF's
`general.architecture` has to be one the bundled server knows, and the exact
size and SHA-256 have to come from where the file is published rather than from
a download someone did once. A link the user adds is held to none of them: the
SHA-256 is checked where one is given, and a file whose header does not say
what its context costs is refused.

Each entry is the strongest at its size: LFM3 1.7B for any phone, Qwen3.5 4B
for one with 8 GB, Ornith-1.5 9B (a Qwen3.5 9B fine-tune, so the same
architecture) for one with 12. Ornith publishes no Q4_0, so its file is
bartowski's. LFM3 is why `LLAMA_CPP_VERSION` is at least `b11951`, the first
release that reads its architecture.

### What the NPU actually is

The honest answer is narrower than the word. ggml has one NPU backend,
`ggml-hexagon`, and it is Qualcomm's Hexagon on Snapdragon with HTP v73 and
later — everything else a phone calls an NPU (MediaTek's APU, Samsung's, Google's
Tensor) has no backend in llama.cpp at all, and Android's own NNAPI, which
would have covered them, was deprecated in Android 15 and never had one either.
The rest of what can be offloaded is a GPU, and **that is what most phones
actually have** — a Pixel's Mali, a Galaxy's, a MediaTek device's — since
Hexagon is Snapdragon alone. So the build carries the **Vulkan** backend too,
and unlike the NPU's it is not opt-in: everything it needs is in the NDK, so it
costs a `libggml-vulkan.so` in the APK and nothing at setup. That library is not
small — 36 MB of embedded SPIR-V, more than the rest of llama.cpp put together —
which is the price of the one accelerator a non-Snapdragon phone can reach.
`build.sh` builds it against Vulkan 1.1, which is Android 9's (API 28): the
backend calls 1.1 entry points directly, so on an API 26 or 27 phone the library
fails to load and `GGML_BACKEND_DL` drops it to the CPU, which is honest, there
being no 1.1 there to offload to. It is Adreno and Mali and everything else with
a Vulkan 1.1 driver; OpenCL on Adreno would be faster on that vendor but is a
second backend to carry, and Vulkan is the one that covers all of them.

So the design does not name the NPU anywhere. `LlamaServer.devices` runs the
server with `--list-devices` and offers whatever it says it found; the settings
page labels each by the kind read off its name, and a phone with nothing is told
so rather than being offered a dropdown of one.

**And nobody has to pick.** The device setting defaults to null, which is *auto*,
and `resolveLocalDevice` turns auto into the best accelerator the server found —
an NPU over a GPU, and either over the CPU — at the moment a model is served.
The CPU used to be that default, and on a phone with an accelerator it is the
slow option that looks hung, so a turn now offloads by itself. The picker keeps
a CPU entry below the accelerators, mapped to `LocalDevice.cpu` rather than null,
for the one who wants to rule the accelerator out; ggml never names a real
device that, so the two do not collide. The probe is memoised in the pool —
`--list-devices` spawns the server, and what a phone has cannot change while the
app runs — and resolved before the running-server check, so auto compares the
device actually used and not the word. Which backends a build carried
is the build's business and which of them find hardware is the phone's, and only
the binary knows both.

What auto is *not* is measured. It is a two-tier preference — an NPU before a
GPU, the first of a kind otherwise — with no benchmark behind it and nothing
comparing either against the CPU. That is worth being honest about rather than
fixing with a timing run nobody asked for, so the running row on the settings
page draws the device the model actually ended up on. `LocalLlmState.device`
carries it in the picker's vocabulary rather than llama.cpp's, which is what
keeps `noDevice` out of the UI.

**The CPU is a device to name, not a flag to leave out.** `resolveLocalDevice`
answers `none` for it — llama.cpp's own word — and `-dev none` is passed like any
other device. Omitting `-dev` is *auto* down in llama.cpp, which is not the same
auto as ours: it builds a device list out of every GPU it can see, and `-ngl`
defaults to -1, which is every layer. So a picker set to CPU on a phone with a
Vulkan driver used to run entirely on the GPU — the model was as slow as ever,
the UI stuttered because the compositor was sharing the GPU with it, and the CPU
cores slider moved nothing, since there was nothing on the CPU to move.

What the Hexagon backend does *not* need is a signature. It enables an unsigned
process domain itself on the DSP, so an ordinary APK can drive the NPU — the
thing that would otherwise have made this a Qualcomm-partners feature. What it
does need is Hexagon SDK 6.6 or later at **build** time. `tool/android/setup.sh`
fetches it — Qualcomm's own route wants a package manager installed on the host,
so this is the Community Edition repackaging llama.cpp's own CI builds in, pinned
by SHA-256 in `versions.sh` — and `build.sh` picks it up from where that leaves
it. CI fetches it as well, so what a release ships is what a local build makes.
Nothing else changes when it is there: the backend arrives as two more
`libggml-*.so` and is found the way the CPU's is.

It also decides the catalog. The Hexagon backend repacks **Q4_0, Q8_0 and
MXFP4** and nothing else, so every entry in `local_model.dart` is Q4_0 — a
K-quant is a model that quietly runs on the CPU on the one device that has an
NPU to run it on.

### Where it lives, and what it costs

The binaries are in the native library directory, and for the reason git and
proot are: it is the only place an app targeting a modern Android may execute a
file from. Here that directory is load-bearing twice over, because the DSP's own
half of the Hexagon backend is resolved out of it too — `ADSP_LIBRARY_PATH` is
set to the same string as `LD_LIBRARY_PATH`, whether or not this build carried a
Hexagon backend, since the answer is the same directory either way and a build
that grows one should not also have to grow a line here. `LD_LIBRARY_PATH` is
not optional: the server is exec'd by path with no rpath in it, so libllama and
the backends beside it are found through that and nothing else.

**The CPU backend is built for armv8.2 with dotprod**, and it is the difference
between a model that answers and one that looks hung. Cross-compiling, ggml
appends no `-march` unless it is given `GGML_CPU_ARM_ARCH`, and the NDK's arm64
default is baseline armv8-a — which defines neither `__ARM_FEATURE_DOTPROD` nor
`__ARM_FEATURE_FP16_VECTOR_ARITHMETIC`. Both are what every Q4_0 fast path in
ggml is `#if`'d on: the whole of its ARM repack file, and the gemv and gemm in
its quants. The catalog is Q4_0 throughout for the NPU's sake, so a baseline
build runs the one format it accelerates down the one path it does not, and
prompt processing is minutes rather than seconds. `GGML_CPU_ALL_VARIANTS` is
what would pick per device instead and is not offered here — ggml builds the ARM
variant list on Linux only — so it is one floor for every phone, and dotprod is
2018 where i8mm would be 2022.

**The little cores are left out of the thread count.** llama.cpp's own default
is every physical core, which on a phone is wrong in a way it is not on a
desktop: the cores are not alike and ggml's threadpool moves at its slowest
thread's pace, so a little core holds up every big one beside it. `bigCoreCount`
ranks them by what the kernel says each one's ceiling is and takes everything
above the floor. A machine of one tier gets all of them, and one the kernel will
not answer for passes no `-t` at all and leaves the choice where it was. It is
read only where the pool is built, so a desktop whose cpufreq answers nothing
falls back to llama.cpp's own default — which, on a desktop of alike cores, is
the right one.

**arm64 only, and that is a size decision — on Android.** The server and its
libraries are about 55 MB stripped — the Vulkan backend's `libggml-vulkan.so`
is 36 MB of that on its own — and three ABIs of it would be most of what a
phone downloads. It is most of why the release APK is split per ABI: see
"Releasing". Nothing is lost: a 32-bit phone cannot map a two-gigabyte model
at all, and x86_64 Android is an emulator. A build without it leaves
`LocalLlm.available` false, and the settings page says so — naming on the web
what a browser cannot do, and on a desktop that the build ran without
`tool/linux/build-llama.sh`, which is a build fault in the sense a missing
proot is.

**Linux carries the same server, built natively.** `tool/linux/build-llama.sh`
builds the pinned release for the host — the same cmake choices the Android
build makes, minus the NDK's: no toolchain file, and `GGML_NATIVE=OFF` where a
distributed binary needs ggml's runtime dispatch rather than this machine's
`-march`. The backends are CPU and Vulkan, the Android build minus the NPU,
and `GGML_BACKEND_DL` keeps them loadable-at-runtime so a machine with no
usable Vulkan driver runs the CPU rather than failing. `linux/CMakeLists.txt`
installs the staged output into the bundle's `lib/`, which is where
`platformLocalLlm` looks for it beside the executable — so a build without the
script still builds, and says what it is missing rather than pretending. The
server is started under `setpriv --pdeathsig TERM` where `setpriv` is on
`PATH`, so a crashed or killed app does not leave it holding the model's
memory; the death signal follows the spawning thread, which is the root
isolate's and lives as long as the app. The
desktop judgement the first version recorded — that Ollama and LM Studio are
the better answer there — stands for a machine that has one installed; what
changed is that a machine with nothing on it now has the zero-setup option a
phone always had, the same catalog and the same flow.

The weights go to `<cacheDir>/llm/<id>/model.gguf` with a `.complete` marker
written last, beside the voice models and a downloaded Linux and outside the
data directory for the same two reasons: `backup.dart` zips that directory whole
and a restore *replaces* it, so a model in there would be a gigabyte in every
export and a deletion on every restore.

`FileLocalModelStore` is `FileRootfsStore` without the unpacking: a `DownloadRun`
and, after it, the checksum where there is one, the header read, and the record.
`LocalModelDownloads` is a third `Downloads<T>` beside the voice models and the
Linux, and the rows are `CatalogTile` and `CatalogAction` like theirs — see "A
catalog of things to download" — with the facts as tags rather than a sentence.

Where it parts company with the other two is that the list is the disk's, not
the catalog's: `downloadedSync()` reads the records once and is kept in step by
`install` and `delete`, and `delete` takes an id so that anything on disk can
be removed. The settings page draws the catalog, then a row for each model
added by link this session until it lands, then every other downloaded model,
delete and nothing else.

It is the third catalog and by far the largest — a couple of gigabytes where a
rootfs is four megabytes — which is what makes the notification's own throttle in
`Downloads._publish` matter here rather than being a nicety.

**The server is bound to 127.0.0.1 and given a key generated per launch.** Every
app on the device can reach the loopback address, so without one any of them
could spend this model's battery. The key is never written down — it lives in
the running `LlamaServer` and in the provider config it hands the registry, and
both go when the server does.

### Prefilling the system prompt

The first turn of any chat pays for the whole system prompt at once — a couple
of thousand tokens of instructions and tool schemas, which on a phone's CPU is
minutes before a word is generated. Prefilling moves that wait off the first
chat: when a local model is the default and the On-device toggle is on, the
system prompt is warmed in the background so the server has its KV in a slot
before a chat asks.

**The split is what makes it cheap.** The system prompt used to open with the
conversation's workspace path, which is per-chat, so no two chats shared a
cacheable prefix. Moving the workspace to the end of the prompt bought most of
that back — the long body above it is the same text for every chat, and
llama.cpp's slot cache matches tokens, so it reused the head — but it left the
whole thing one message, and a message is what `kvPrefixKeys` hashes. Two chats
therefore agreed on no *key*, and the body the warm-up wrote to disk was filed
under a name no chat ever looked for: the live slot helped, the dump could not.

So the per-chat half is its own system message now. `systemPrompt` is the body
and nothing else; `turnPrompt` is the workspace and whatever an `@agent` added,
sent after it. The warm-up sends the body alone (`createLocalPrefill` in
`core/platform/`), so its shortest key *is* every chat's shortest key — the two
hash the same message — and a chat reopened on a cold server restores what the
warm-up left rather than reading the body again. The date rides on the user
message rather than the prompt (`userTurnText`), so the one value that changes
every turn is never in the cached prefix.

What it costs is two system messages on the wire. `AnthropicClient` already
joined every system message into its one `system` parameter, so that provider
sees no change at all, and the OpenAI shape takes a list of messages with roles
on them. A chat template that assumed exactly one system message would be the
thing to watch; the bundled server renders each message under its own role.

**It is the on-device provider's own feature and touches no shared interface.**
`LocalPrefill` drives the existing `LocalLlm.serve` and an `OpenAiClient` with
`returnProgress` — the same two a real turn uses — and cancels the stream at the
first token, by which point the prompt is read and cached. Nothing on
`LlmClient`, `LlmProvider` or `AgentBackend` grew a method; a hosted provider
sees none of it. The one new port method is `BackgroundWork.prefilling`, which
is the foreground service, not a provider — and its notification is a visible
one rather than the silent hold turns and downloads keep, since the user set it
going and then left.

The warm-up prompt and tools are built from one `ToolOffer`, read the way a
turn reads its own, so the warmed prefix is the one those turns send — the
offer in `createLocalPrefill` is a top-level turn's defaults and has to stay
in step with `BuiltinAgent.offer`, or the cache warms a prefix nothing
reuses. The profile is in the prompt too: a chat with an unchanged
profile reuses it, and one after a profile edit reuses only the body above it
and reprocesses the profile in its tail, which is small and self-heals on that
first turn — so nothing rewarms on a profile change.

**A warm-up reads the disk before it reads the prompt.** The body is written to
disk by the mechanism the next section describes, so the second launch has one
already: `LocalPrefill` serves the model, asks `LocalKvCache.warm` for the body,
and — where that hits — is finished, having sent no prompt at all. It is why
`warm` answers `bool` where a turn ignores it; a turn sends its prompt either
way, and only this can be over before it starts. Without it the disk cache only
ever helped a chat, and the minutes came back at every launch.

**Stopping is the user's, and the work is this object's.** The notification's
Stop reaches `BackgroundWork.stopRequests` as `BackgroundJob.prefill` and
`LocalPrefill` is what subscribes — the button asks, the owner of the work acts,
the way a download's does and for the reason `TurnKeepAlive` does it in its own
constructor. It closes the request rather than only marking the run superseded:
a generation is noticed at the next chunk, and while a prompt is being read that
is however long the rest of it takes, which is the whole reason there is a Stop.

**A warm-up must not outlive the server it is warming**, and that invariant is
in `LocalPrefill` rather than at any of the places that stop one. Unload all is
the way it was first noticed; deleting a model is another, since `unpick` stops
everything; and a turn asking for a second model past `maxLocalModels` is a
third, which no button could have known about. What all three share is
`LocalLlm.running` losing the row — published *before* the pool kills anything —
so `_whileServed` watches that and cancels. It arms before the serve and fires
only after the model has been seen running, because until the pool has published
the row "not in the list" is a warm-up that has not started rather than one
whose server has gone.

### Persisting the KV cache to disk

The prefill only ever helped the *first* turn. Reopening a long multi-turn chat
was the same wait made worse: with the live server gone (a reload, an app
restart, the model evicted for another), the whole history — thousands of tokens
— is reprocessed from scratch, which on a phone is minutes just to resume a
conversation the user already had. `LocalKvCache` closes that by saving the
server's slot KV to disk with llama.cpp's slot save/restore, and restoring it
when the chat comes back.

**It is content-addressed, and that is what keeps it the provider's own.**
Nothing hands it a chat id: a dump is keyed on a hash of the prompt prefix that
produced it (`kvPrefixKeys` — one key per message boundary, over the messages
and the tools that head every request), so no identifier crosses
`LlmClient.stream` and no interface a hosted provider shares grew a method — the
same constraint the prefill kept. `LocalPoolClient` restores the longest saved
prefix of a request before the turn and saves the whole prompt after it; both
are best-effort, so a miss or a build without slot save/restore just pays the
prompt the way it did before. The code is `local_kv_cache.dart` (the port and the
pure key/eviction math, web-safe) and `file_kv_cache.dart` (the disk and the
`/slots/0` requests, Android only).

**Invalidation is the keying, not a bookkeeping step.** A rewound or edited chat
hashes to a different key, misses, and its stale dump ages out of the LRU on its
own. A dump is also unreadable by a different model, context length, or KV quant,
so the filename carries a `kvNamespace` of exactly those — plus the device
setting, which is the picker's word rather than the resolved one, so Auto and CPU
keep separate dumps on a phone where they launch the same server. A change to any
of them lands the dump where nothing looks for it, and the old namespace's files are
reaped by the byte budget rather than tracked. One directory holds every
namespace, because `--slot-save-path` takes a basename and the name is where the
namespace rides; the pool and the cache are built from the one join
(`_kvCacheDir`) so they cannot disagree on it.

**On by default at ten prefixes** (the "Cached prompts" picker; `Off` writes
nothing), because the win is large and the reopen is the common case. The dumps
are not small — a few thousand tokens of a 2B's KV is on the order of hundreds of
megabytes even at the `q8_0` quant the server runs with when the cache is on — so
there are two bounds: the newest N of the active namespace, and a disk budget
across every namespace so an abandoned model's dumps cannot pile up. The quant is
near-lossless but still a change to generation, so it rides on the cache being
on: turn it off and the server runs f16, the behaviour it had before this.

**The number counts prompts, and the picker used to say chats.** One dump is one
request: `LocalPoolClient.stream` saves after each, and the agent calls it once
per step, so a turn that runs five commands writes five — and the bound is over
every chat at once rather than per chat. "10 chats" promised ten conversations
kept warm and, for a turn of any length, meant closer to two. The setting is
`localModelKvCachePrompts` now and still reads the old key, so nobody's choice is
reset. Which bound actually bites is the disk budget more often than the count:
at 128 KiB a token for the 4B, halved by `q8_0`, a 3,000-token prompt is around
190 MB and four gigabytes holds about twenty.

The prefill persists too, but the shortest key — the system+tools body every
chat shares (`keys.last`) — so the warmed body survives a reload and every
chat's own restore finds it. That last clause is only true because the body is
its own message: while the workspace was in it, a chat's shortest key was over
its own directories and the warm-up's dump sat there unread. It serves with the
same threads and cache flags a real turn does, or the first turn would find the
server launched differently and relaunch it, throwing the warm away.

**Eviction reads a dump's date as when it was last used, not when it was
written**, and `FileKvCache.warm` touching the file it restored is the whole of
what makes that true. It matters because of the body: nothing but the prefill
ever writes it, so on write order it is the oldest of its namespace within a
chat or two and the oldest file outright soon after, and both bounds reap from
that end — the count set to thirty being what deletes the prefix all thirty
restore from, so the next launch prefills from nothing again. Exempting that one
file by name was the first answer and a worse one: it left a second model's body
just as exposed, made an abandoned model's immortal, and threaded which key is
special through three signatures to reach the sort. Sorting on use fixes all of
it in one line, and an abandoned body then ages out the way everything else
does.

The **cores** setting is the other half of the On-device machine questions:
`localModelThreads` caps how many the server runs on (the slider, from every big
core down to one), trading tokens-per-second for battery. Null is the default —
every big core (`bigCoreCount`) — and the slider's top is `LocalLlm.maxThreads`
so it never offers more than the server would use anyway.
