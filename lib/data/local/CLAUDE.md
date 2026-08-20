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

Nothing being checked in is also why a locally built APK is the one that ships
without them: a `dist/` from an older run stages what it has and no more, and
`jniLibs/` is ignored, so the gap shows up on a phone rather than in a diff.
Missing proot then reads as the Terminal page having lost its catalog, which is
drawn from the same answer. **So the page says which it is**: an ABI that
Android answered with and no proot beside it is a build fault, and it names the
two commands that fix it rather than describing a device that cannot run a
Linux. Only whoever built the APK can reach that, since the release build
refuses one with no proot in it.

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
`settings.json`: its base URL holds a port asked of the OS at launch, so a file
naming it would be stale by the next one. It goes **first** in the list, which
is what decides a collision — `localProviderId` is the app's name, and a
`settings.json` that happens to use it is shadowed rather than allowed to take
the model's own endpoint away from it. What is stored is the pick —
`localModelId`, `localModelDevice`, `localModelContext` — and `applyLocalModel`
is the one function that makes what is running agree with it. Two callers, far
apart: the settings page, where a model is picked, and `AppSession.start`, where
a pick from a previous run is honoured.

**The provider appears the moment a model is picked, not when it answers.**
Mapping a four-gigabyte model takes the better part of a minute, and a chat
pinned to it must not lose its model for that minute after every launch. So the
endpoint is in the list while it loads and `PendingLlmClient` — the same shape
as `GatedLlmClient` — waits for `whenReady` before the first request goes
through. **It rides on the endpoint rather than on the registry**: an
`LlmEndpoint` is a config and, where reaching it is not the ordinary thing, the
client to reach it with. The first version had the registry comparing a provider
id against a name it had to be told was reserved, which is a special case in the
one place that should know nothing about who its endpoints are — and one more
`==` arm for every endpoint that ever needs decorating. A turn sent at a loading model waits; a turn sent at a model that will
never load gets the server's own last words as an `LlmException`, which for a
model too large to fit is the only place that is said at all.

**Nothing loads a model on its own.** A pick is a gigabyte of the phone's memory
and minutes of its battery, so it is picked in settings and nowhere else — a
download does not load it, and a chat pinned to a model that is not loaded says
the provider is not configured rather than quietly starting one.

### What is in the catalog, and why it is one family

Three things have to be true before a row can exist, and together they cut the
field down to almost nothing: the publisher has to ship **Q4_0** — see "What the
NPU actually is" — the GGUF's `general.architecture` has to be one the bundled
server knows, and the exact size and SHA-256 have to come from the publisher
rather than from a download someone did once.

What survives is Qwen3.5, four sizes of it. Not a preference for the vendor:
Gemma 4's E4B is the near miss and shows the shape of the comparison. It is the
one model published *as* Q4_0 — quantization-aware trained, so the quant this
list is forced into costs it nothing — and it is still twice the file of
Qwen3.5 4B for a lower LiveCodeBench. A row nobody should pick is a row that
only makes the list longer.

**None of them is a coder model**, which is the change from the list before it.
Small coder-tuned weights stopped being published: the current official one is
Qwen3-Coder-Next, which is 48 GB at Q4 and arrives in four pieces. What replaced
them is a general model of this size beating the old specialists at code
outright, and being far better at the conversation around it — which is most of
what this agent does between edits.

The sizes are not interchangeable and the notes say so. 0.8B and 2B answer
directly; 4B and 9B think first, which on a phone is a wait long enough to
notice and is also why they are better over a long turn.

### What the NPU actually is

The honest answer is narrower than the word. ggml has one NPU backend,
`ggml-hexagon`, and it is Qualcomm's Hexagon on Snapdragon with HTP v73 and
later — everything else a phone calls an NPU (MediaTek's APU, Samsung's, Google's
Tensor) has no backend in llama.cpp at all, and Android's own NNAPI, which
would have covered them, was deprecated in Android 15 and never had one either.
The rest of what can be offloaded is a GPU, through OpenCL on Adreno or Vulkan.

So the design does not name the NPU anywhere. `LlamaServer.devices` runs the
server with `--list-devices` and offers whatever it says it found; the settings
page labels each by the kind read off its name, and a phone with nothing is told
so rather than being offered a dropdown of one. Which backends a build carried
is the build's business and which of them find hardware is the phone's, and only
the binary knows both.

What the Hexagon backend does *not* need is a signature. It enables an unsigned
process domain itself on the DSP, so an ordinary APK can drive the NPU — the
thing that would otherwise have made this a Qualcomm-partners feature. What it
does need is Hexagon SDK 6.6 or later at **build** time, which is behind a
Qualcomm account and not redistributable, so CI builds without it and
`HEXAGON_SDK_ROOT` is what turns it on. Nothing else changes when it is there:
the backend arrives as two more `libggml-*.so` and is found the way the CPU's
is.

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

**arm64 only**, and that is a size decision. The server and its libraries are
about 18 MB stripped against git's 12, and three ABIs of it would put 56 MB into
the universal APK. Nothing is lost: a 32-bit phone cannot map a two-gigabyte
model at all, and x86_64 Android is an emulator. A build without it leaves
`LocalLlm.available` false, which is also what the desktops and the web get —
and there the settings page says so and points at Ollama and LM Studio, which
are two of the presets and a better answer than a second copy of llama.cpp
inside this app.

The weights go to `<cacheDir>/llm/<id>/model.gguf` with a `.complete` marker
written last, beside the voice models and a downloaded Linux and outside the
data directory for the same two reasons: `backup.dart` zips that directory whole
and a restore *replaces* it, so a model in there would be a gigabyte in every
export and a deletion on every restore.

`FileLocalModelStore` is `FileRootfsStore` without the unpacking: a `DownloadRun`
and, after it, the one thing this download has that the others do not, which is
the checksum. `LocalModelDownloads` is a third `Downloads<T>` beside the voice
models and the Linux, and the rows are `CatalogTile` and `CatalogAction` like
theirs — see "A catalog of things to download". Nothing here needed a new
mechanism, which is the point: the catalog is a const list, the store is a
marker and a hash, and everything between them was already written.

The one place it parts company with the other two is `installed()`, which reads
the directory names off the disk rather than the catalog, and `delete`, which
takes an id rather than a `LocalModel` so that what `installed()` finds can
actually be acted on. Both exist for the same event: the catalog replaces a
generation of models, and every id it drops is a couple of gigabytes that no
row would otherwise mention and nothing in the app could remove. The settings
page draws those as rows of their own, delete and nothing else — there is no
`Downloads` entry behind one to cancel or fetch again.

It is the third catalog and by far the largest — a couple of gigabytes where a
rootfs is four megabytes — which is what makes the notification's own throttle in
`Downloads._publish` matter here rather than being a nicety.

`-c` is the setting that decides whether Android kills the app, and it defaults
far below what any of these models was trained for. The weights are mapped and
paged; the KV cache is not.

**The server is bound to 127.0.0.1 and given a key generated per launch.** Every
app on the device can reach the loopback address, so without one any of them
could spend this model's battery. The key is never written down — it lives in
the running `LlamaServer` and in the provider config it hands the registry, and
both go when the server does.
