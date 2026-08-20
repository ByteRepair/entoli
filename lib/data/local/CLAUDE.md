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
else. It is layered in `LocalShell` beside the defaults that were already there,
so the one place that decides what a command runs under decides this too, and
settings still win over all of it — a variable the user set is the one that
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

Building them is `tool/bundle/`: `versions.sh` pins what is built and its
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

**A `Sandbox` replaces the `Toolset` rather than layering over it.** Every path
the host toolset names is the host's, and a `TMPDIR` under the app's own
directory is not where a guest's `/tmp` is. So the guest gets the guest's `PATH`
and nothing of the host's — and settings still win over both, which is the rule
that was already there.

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
signature check `LlmRegistry` makes. **It rides on the endpoint rather than on
the registry**: an `LlmEndpoint` is a config and, where reaching it is not the
ordinary thing, the client to reach it with. The first version had the registry
comparing a provider id against a name it had to be told was reserved, which is
a special case in the one place that should know nothing about who its endpoints
are — and one more `==` arm for every endpoint that ever needs decorating. A
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

**The default is the model's own**, `LocalModel.defaultContext`: `kvBudgetBytes`
divided by what one token of *that* model's KV cache costs, rounded down to a
power of two. The cost is `2 × block_count × head_count_kv × key_length × 2` —
K and V, every layer, f16 — read off each GGUF's metadata rather than guessed
from the parameter count, which does not decide it. The catalog splits two and
two: 48 KiB a token for the 0.8B and 2B, 128 KiB for the 4B and 9B, so the same
gigabyte buys 16,384 tokens on the small pair and 8,192 on the large. One
constant for all four is what made the small models as cramped as the large ones
for a third of the memory.

It matters more than it looks, because the agent's own prompt is not small: the
system prompt and the tool schemas are about 2,700 tokens before the user has
typed anything. The 4,096 this used to default to left roughly one exchange.

The Context setting overrides it for every model at once. That is the honest
shape now that any downloaded model can be the one a turn asks for — there is no
longer a single picked model for a per-model override to attach to.

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

What the Hexagon backend does *not* need is a signature. It enables an unsigned
process domain itself on the DSP, so an ordinary APK can drive the NPU — the
thing that would otherwise have made this a Qualcomm-partners feature. What it
does need is Hexagon SDK 6.6 or later at **build** time. `tool/android-setup.sh`
fetches it — Qualcomm's own route wants a package manager installed on the host,
so this is the Community Edition repackaging llama.cpp's own CI builds in, pinned
by SHA-256 in `versions.sh` — and `build.sh` picks it up from where that leaves
it. CI still builds without it, because what the NPU build emits is compiled by
Qualcomm's toolchain against Qualcomm's headers and whether it can ship is a
licensing question. Nothing else changes when it is there: the backend arrives as
two more `libggml-*.so` and is found the way the CPU's is.

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
not answer for passes no `-t` at all and leaves the choice where it was.

**arm64 only**, and that is a size decision. The server and its libraries are
about 55 MB stripped — the Vulkan backend's `libggml-vulkan.so` is 36 MB of that
on its own — and three ABIs of it would be a large part of the universal APK.
Nothing is lost: a 32-bit phone cannot map a two-gigabyte model at all, and
x86_64 Android is an emulator. A build without it leaves
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

The reorder is what makes it cheap. The system prompt used to open with the
conversation's workspace path, which is per-chat, so no two chats shared a
cacheable prefix. It now ends with the workspace (`## Your workspace`), so the
long body above it is identical for every chat and is one prefix the pool's slot
cache reuses across them. The warm-up sends that body with the workspace left
empty (`createLocalPrefill` in `core/platform/`), so the shared head lands in a
slot and every chat after only pays its own short tail. The date rides on the
user message rather than the prompt (`withNow`), so the one value that changes
every turn is never in the cached prefix.

**It is the on-device provider's own feature and touches no shared interface.**
`LocalPrefill` drives the existing `LocalLlm.serve` and an `OpenAiClient` with
`returnProgress` — the same two a real turn uses — and cancels the stream at the
first token, by which point the prompt is read and cached. Nothing on
`LlmClient`, `LlmProvider` or `AgentBackend` grew a method; a hosted provider
sees none of it. The one new port method is `BackgroundWork.prefilling`, which
is the foreground service, not a provider — and its notification is a visible
one rather than the silent hold turns and downloads keep, since the user set it
going and then left.

The warm-up prompt and tools are built from the same `systemPrompt` and
`agentTools` a turn uses, so the warmed prefix is the one those turns send —
the tool booleans in `createLocalPrefill` are `BuiltinAgent`'s defaults for a
top-level turn and have to stay in step with them, or the cache warms a prefix
nothing reuses. The profile is in the prompt too: a chat with an unchanged
profile reuses it, and one after a profile edit reuses only the body above it
and reprocesses the profile in its tail, which is small and self-heals on that
first turn — so nothing rewarms on a profile change.

The warm-up's own cache is the running server's slots, which a reload loses —
but the body is also written to disk by the same mechanism the next section
describes, so a reopen after a restart restores it rather than warming again.

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
so the filename carries a `kvNamespace` of exactly those — a change to any of
them lands the dump where nothing looks for it, and the old namespace's files are
reaped by the byte budget rather than tracked. One directory holds every
namespace, because `--slot-save-path` takes a basename and the name is where the
namespace rides; the pool and the cache are built from the one join
(`_kvCacheDir`) so they cannot disagree on it.

**On by default at ten prefixes** (the "Cached chats" picker; `Off` writes
nothing), because the win is large and the reopen is the common case. The dumps
are not small — a few thousand tokens of a 2B's KV is on the order of hundreds of
megabytes even at the `q8_0` quant the server runs with when the cache is on — so
there are two bounds: the newest N of the active namespace, and a disk budget
across every namespace so an abandoned model's dumps cannot pile up. The quant is
near-lossless but still a change to generation, so it rides on the cache being
on: turn it off and the server runs f16, the behaviour it had before this.

The prefill persists too, but the shortest key — the system+tools body every
chat shares (`bodyOnly`) — so the warmed body survives a reload and every chat's
own restore finds it. It serves with the same threads and cache flags a real turn
does, or the first turn would find the server launched differently and relaunch
it, throwing the warm away.

The **cores** setting is the other half of the On-device machine questions:
`localModelThreads` caps how many the server runs on (the slider, from every big
core down to one), trading tokens-per-second for battery. Null is the default —
every big core (`bigCoreCount`) — and the slider's top is `LocalLlm.maxThreads`
so it never offers more than the server would use anyway.
