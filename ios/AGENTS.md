# The iOS half

## The icon

`Runner/entoli.icon/AGENTS.md` is a symlink into the macos half: the Icon
Composer package both Apples compile the app icon from — one file for iOS and
macOS, its layers generated from `assets/icons/cookie.svg`, the launcher
switching being Android's `activity-alias` alone so only the default has a
copy here.

## Export compliance

The app is in the middle row of Apple's table: **industry-standard algorithms
not provided by the OS**. Sync's own layer is ChaCha20-Poly1305 with X25519
and Ed25519 from the `cryptography` package, WebRTC brings its own DTLS and
SRTP, and Dart's HTTPS is the engine's BoringSSL rather than `URLSession`. None
of it is proprietary, so there is no CCATS; the one document that row asks for
is a **French encryption declaration** (ANSSI), and only for distribution on
the App Store in France.

So `ITSAppUsesNonExemptEncryption` is `false` in `Runner/Info.plist` **on the
condition that France is excluded from the app's availability** in App Store
Connect; with France out there is no documentation to provide, and the key is
what stops App Store Connect asking on every upload. Adding France means filing
the ANSSI declaration first, uploading it under App Information → App
Encryption Documentation, and then setting the key `true` beside the
`ITSEncryptionExportComplianceCode` Apple issues on approval. The note lives
here rather than as a comment beside the key because Xcode rewrites
`Info.plist` without its comments.

## Privacy declarations

App Store processing reads the binary, not the UI, so a key is owed for
whatever is linked, offered or not. `NSCameraUsageDescription` is the
prompt the pairing scanner raises, and would be owed even without it, since
`mobile_scanner` and WebRTC link `AVCaptureDevice`; an upload without it is
refused.
`NSLocalNetworkUsageDescription` is the wording of the prompt the first
local-network connection raises: the same-LAN pairing (`SignalingServer`
listens on `0.0.0.0` here too), sync over the LAN after it, or a provider the
user runs on their own network (an Ollama or LM Studio at a LAN address).

`Runner/PrivacyInfo.xcprivacy` declares the required-reason APIs the Runner
binary itself calls — the force-loaded iSH core above all — which the plugins'
and frameworks' own manifests do not cover: `stat`/`fstat`/`lstat`/`fstatat`
as file timestamps (C617.1, inside the container), `fstatfs`/`fstatvfs` as
disk space (85F4.1, the guest's `df`), and `mach_absolute_time` as boot time
(35F9.1, elapsed time). Its tracking and collected-data entries are empty
because `PRIVACY.md` says so, and they follow it rather than this file. A new native library or plugin wants its
undefined symbols checked against Apple's list (`nm -u` on the built
binary) and a reason added here for any new category.

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
in the running app over the VM service.

1. **Install a rootfs and run a command — done, on the simulator.** The
   rootfs half ran end to end (fetch, SHA-256 check, in-process unpack,
   `.complete` marker), and the first command through the guest has since
   run: a `!uname -a` bypass turn and a full agent turn through the `bash`
   tool both came back rc 0 with iSH's own uname string, cwd
   `/root/chats/<id>` — `ish_boot`/`ish_session_init`/`ish_session_run`
   exercised end to end, on record in the chat's `conv.jsonl`. What the
   simulator cannot answer is the device half of it, which is the next item.
2. **The link wiring is xcconfig, not CocoaPods.** `ios/Flutter/Ish.xcconfig`,
   which Debug and Release both include, force-loads the right `IshCore.xcframework` slice per
   SDK and name the system libraries (`-lz -lbz2 -lxml2 -lsqlite3 -liconv`)
   a podspec would have carried; there is no Podfile. The framework itself
   is built by `tool/ios/ish/build.sh` (LLVM's clang and lld wanted for the
   vdso; `brew install llvm lld`, both keg-only and not on PATH by default).
   `tools/fakefsify.c` is deliberately not compiled — its `main()` collides
   with the app's; `tools/fakefs.c`'s `fakefs_import` is what
   `ish_fakefsify` wraps. The app build never runs `build.sh`, so a local
   `dist/` is whatever was built last: after `ish_bridge.c` changes, run it
   again, or the app links a bridge without the new entry points and the
   lookup throws (CI's cache is keyed on the bridge, so a release rebuilds).
   Each looked-up name is kept by hand — `Ish.xcconfig`'s `ISH_KEEP_NAMES`
   against the dead-strip, on for arm64 alone since the x86_64 simulator slice
   links no iSH, and `Release.xcconfig`'s `STRIP_STYLE` against the archive's
   strip, both saying why — and `test/data/local/ish_test.dart`
   fails when the list and `ish_ffi.dart`'s lookups disagree; `nm -gU` on
   the archived `Runner` is how to see that every name is there.
3. **The runtime path on a real device.** The IshShell/FFI/dispatcher chain
   has only answered on the simulator so far; a device run is the step left
   before a store build.

## The interrupt, and its escalation

`IshShell` delivers a stop on the calling isolate, not through the worker:
the worker parks in a run's poll/read loop for the whole of the command, so
a message to it would queue behind the run it is meant to end. The bridge's
`ish_session_interrupt` is a `send_group_signal` to the shell's process
group — every init child is its own session leader, so the group is the
shell and the command it runs, the Ctrl-C LocalShell sends; looked up under
`pids_lock` by the guest pid, never a task pointer that dies with the shell,
and honoured by the guest's interpreter threads at their next scheduling
point — so a direct FFI call over the session handle's address (which
`init`'s answer carries to the caller) is the same call, delivered on time.

Output rides the loop as it happens: every read the worker makes is resolved
by [IshRunBuffer] — the marker parse, the bridge's own C until now — and
what cannot be marker text goes to the run's watch at once, so a command's
output appears in the chat while it runs, the contract the host shell keeps.
The marker's parse is the suite's now (`ish_session_test.dart` pins it over
a fake transport at byte level, splits included), and the reply keeps the
bridge's 64 KiB head cap for what the model sees. The loop still parks
between chunks, which is what makes a message-queued stop wrong.

A guest that ignores the SIGINT is answered a second later by its
escalation, `ish_session_hangup`: SIGKILL to the group, and one byte
dropped into a wake pipe the run polls beside its stdout. The byte is what
returns the worker: a child that left the group can hold the guest's write
end for its own life — without the byte, a hung-up run would wait on the
child rather than on the second. The read end is not closed there: the
worker may be reading it, and a close from another thread hands its number
to the next open. The run returns "did not complete" and hands teardown back
to the queued destroy, which closes every pipe end. A session closed with a
run still pending is hung up first, for the same reason a stop is not
posted: the destroy would otherwise queue behind the run.

A run the guest answers within the second — the SIGINT honoured, rc 130 —
leaves the session standing, cd and exports with it. On a timeout that is a
deliberate split from LocalShell, whose escalation kills the group at the
command's own sentinel to reach what ignored the interrupt; the guest's
session state is worth the survivors here, and the one-shot (no session
state to keep) escalates whichever way, LocalShell's side. For a stop the
contract is the same one LocalShell keeps: the escalation answers a run
still pending at the second, and nothing else.

The session and one-shot logic over this seam is pinned by
`test/data/local/ish_session_test.dart` over a fake transport; that a real
guest honours the 130, that a hangup unblocks the loop, and that output
arrives live is the simulator's hand-run, like the wire — witnessed on this
build: the stop ends a running command at once, the escalation answers a
SIGINT-ignoring one on its second, and output reaches the chat while the
command still runs.

The worker itself is spawned single-flighted (`IshWorker._ensure`), which is
also where the review's spawn race died, and it fails every pending reply
when it dies so a crashed FFI call cannot leave a turn hanging. Every
session and every one-shot run
owns a worker of its own, so one chat's command does not wait on another
chat's — what the emulator serializes for them is only the boot itself
(`IshWorker._ops`), since the bridge's boot and binds are the C
state two isolates could reach at once; the runs stay parallel, each
interpreter being its own task.

## Voice mode

Voice mode is Apple's engines, behind the same `agent_chat/voice` contract
`VoiceChannel.kt` answers on Android — `VoiceChannel.swift`, which lives in
`macos/Runner/` and is compiled into both Runners the way
`RemindersShared.swift` is, its `AVAudioSession` half under `#if os(iOS)` —
and the Dart `Native*` strategies shared with `android_voice.dart`.
Recognition is on-device `SFSpeechRecognizer` only and synthesis is
`AVSpeechSynthesizer`, so no audio leaves the device — the transcript does, to
the chat's model like any typed message, which is what both usage strings say —
and the languages the settings offer are the on-device intersection.
`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` are
the two keys this rides on; both grants are asked at the first listening turn
and a refusal is the session's failure to show, not a state anything
remembers. Endpointing is level-based (the shortcut the Touch-to-speak toggle
covers), there is no sherpa here, and `Voice.hasModelCatalog` is what takes
the catalog and the Assistant section off this platform's settings. The
simulator cannot run the recognizer on the iOS 26 line at all — no dictation
"Assistant" assets exist there in any mode, and the task dies with
`kLSRErrorDomain Code=300 "Failed to initialize recognizer"` — so voice's
hand-run was always a real device's, the same hardware run the commands want;
the grants, a spoken turn, push-to-talk and read-aloud are its recipe.

## The Apple model

`AppleFmChannel.swift` answers the `agent_chat/apple_fm` channel — `AppleFm`
and its client are the Dart half, in `lib/data/local/apple_fm.dart`. The model
is the OS's own `SystemLanguageModel`, composed as an ordinary provider
beside the llama pool in `modelProvidersProvider` (`appleProviderId`, an endpoint
carrying its own client), so the registry, the pickers and a chat's pinned
model see a provider like any other. No server: iOS has no exec, and the
framework *is* the model — the llama pool this build never carried is not a
gap here, for once; this entry is.

**It names chats and does nothing else.** The 8,192-token window is mostly
the agent's own prompt and tools — about 6k before the first message — so a
turn on it opens with a compaction every time, which is a chat that works in
name only. `isTitleOnlyModel` (`lib/domain/local_model.dart`) is the one
gate: the backend resolves it for the title's ask alone and refuses a turn
on it with a line saying so, only the Title LLM picker (`ModelRole.title`)
lists it, and the welcome tour does not count it as a model connected — so
an iOS device sets up a provider before its first chat, or downloads an MLX
model (below). Lifting it is the predicate and nothing else, once a slimmer
prompt fits the window.

Three decisions worth knowing before touching it:

- **A tool call is reported and ended, not run.** `BridgeTool` forwards the
  decoded arguments over the channel and throws, and the generation is
  cancelled at the report: the agent in Dart owns the loop, because
  approvals, the recorder and the projections hang off that ownership. What
  the framework would have done with the report — feed it back to the model
  and carry on — is what the cancellation stops; that a thrown tool error
  also ends a `.allowed` generation is the hand-run's to confirm.
- **The history is seeded as text** — prompt and response entries, tool
  calls worded inline — a fresh `LanguageModelSession` per call, nothing
  held between asks. That is the parity the projection enforces for every
  other provider; what it hands over is Apple's own KV reuse, unmissed at
  the 3B-model scale this is for.
- **The context window is the model registry's constant**
  (`contextWindowOf`, 8,192), not a handshake field: the compaction budget
  and the auto-compact threshold both read it there, and the app-wide
  `totalContext` guess is what everything else answers. Where the session
  reports its own counts (iOS 27 and later) they ride the done frame, and
  those are the threshold's real numbers.

The availability is asked once at launch (`platformCreateAppleFm`). The
endpoint exists where the OS *could* run the model — so a device where
Apple Intelligence is off, or its assets still fetching, sees the model and
reads the wording at first turn — and does not exist where the hardware
never will, the same honesty a build with no llama server answers with.
`SystemLanguageModel.contextSize` was not wired through: the registry
constant stands in until a reader wants a channel round trip. The framework
is weak-linked in both xcconfigs; an OS below 26 starts, and the handshake
answers `os`.

The simulator runs the model, on a Mac with Apple Intelligence on — the
host's model answers — so the bring-up is the simulator's as much as a
device's: the welcome chat's tool turns are the quick check, since they
offer a nested object (`ask`) and a string enum (the tone), the two shapes
that once named a node like its root and failed every turn. What the VM does pin is the client's own
protocol over a mock channel — `test/data/local/apple_fm_client_test.dart`:
the streaming, the handoff ending, the history wording, the error map.

## The MLX models

The On-device page's text models here are MLX's: `MlxEngine`
(`lib/data/local/mlx_engine.dart`) is this platform's `LocalEngine`, and
macOS's, wherever the handshake answers `mlx: true` — this build links
mlx-swift-lm's `MLXFoundationModels` and the OS is 27. Below that, or with
the package missing, the engine is `NoLocalEngine` and the page has no text
section. Requiring 27 is for the feature, not the app.

The catalog is `mlxCatalog` (`lib/domain/local_model.dart`): the GGUF
catalog's three sizes in MLX's 4-bit format, each pinned to a commit with
every file's size and SHA-256, downloaded and checked by the same
`FileLocalModelStore` as a GGUF into `<cacheDir>/llm/<id>/`. Only the files
loading needs are fetched. LFM3 has no architecture in mlx-swift-lm, so the
smallest row is Qwen3.5 2B. `MlxFormat` describes a download from its
`config.json`.

The engine decides residency, the way the llama pool does: past
`maxLocalModels` the least recently served is evicted before the next loads.
A generation crosses the same channel and the same client code as the system
model's (`FoundationModelsClient`); what differs is the route — an MLX
generation carries `model` (the catalog id) and `directory`.

### The channel

`AppleFmChannel.swift` answers, beside `handshake`, `generate` and `cancel`,
the residency Dart decides:

- `handshake` → `mlx: true` only where `MLXLanguageModel` exists in this
  build and `#available(iOS 27, macOS 27)`. The import is gated on
  `canImport(FoundationModels, _version: 2) && canImport(EntoliMLX)`: with
  an older SDK there is no `LanguageModel` to hand a session, and
  mlx-swift-lm compiles to an empty module that `canImport` would still
  answer yes for.
- `load {model, directory}` → an `MLXLanguageModel` over
  `ModelConfiguration(directory:)`, capabilities `[.guidedGeneration,
  .toolCalling, .reasoning]`, its `load` closure
  `loadModelContainer(from:using: #huggingFaceTokenizerLoader())`, preloaded
  and kept by `model` in `MlxModels` (`EntoliMLX`, below) — only once its
  weights are in, so a failed load leaves nothing behind. A failure answers a `FlutterError` whose
  message is what the settings row shows.
- `evict {model}` → that instance's `evict()`, and it is dropped;
  `evictAll` → `MLXLanguageModel.evictAll()`, and all of them are.
- `generate` with a `directory` → the session is built on the kept instance,
  loaded first if it is not kept; without one, the system model.

Still the hand-run's to confirm: whether a thinking model's trace stays out
of `part.content` with `.reasoning` declared.

### The build

MLX reaches the Runners prebuilt: `tool/apple/mlx/` is a package,
`EntoliMLX`, whose one public type is `MlxModels`, and `build.sh` builds it
into `tool/apple/mlx/dist/EntoliMLX.xcframework`, a dynamic framework per
platform (iOS, the simulator, macOS; arm64 alone) that both Runners link and
embed. Not run by the app build, as iSH's is not: without it neither Runner
links. Three reasons it is prebuilt rather than a package dependency of the
Runners:

- **`flutter build ios` always passes `-sdk`**, device or simulator, and
  `-sdk` overrides every target's SDK — mlx-swift-lm's tokenizer macro
  included, which has to be built for the Mac it runs on, and fails to find
  swift-syntax when it is built for iOS. The script runs `xcodebuild` itself,
  with a destination and no `-sdk`. macOS never hit it, host and target being
  one platform.
- **The macro has to be trusted**, and a release runner has nobody to click
  Trust & Enable. The script passes `-skipMacroValidation`, which is why the
  pins in `Package.swift` are exact and `Package.resolved` is committed and
  enforced: what runs is the code a person chose by bumping a number.
- **The MLX compile is minutes of C++ and Metal**, which CI caches
  (`.github/actions/apple-mlx`) on the package, its pins, the script and the
  Xcode build.

The module is built with library evolution and its imports `internal`, so its
interface names nothing of MLX's — `MlxModels` hands the channel an
`any LanguageModel` — and the Runners import one module and nothing behind
it. MLX finds its Metal kernels beside its own binary before anywhere else,
so they travel inside the framework (`mlx.metallib` in the flat iOS one,
`Resources/default.metallib` in the versioned macOS one) and the app copies
nothing; the packages' resource bundles sit in the framework's resource
directory, where their accessors look. FoundationModels is weak-linked in
the framework as in the app.

It pins mlx-swift-lm 3.32.3 (`MLXFoundationModels`, `MLXLLM` — which
registers the architectures; without it a load fails with
`noModelFactoryAvailable` — `MLXLMCommon` and `MLXHuggingFace`) and
swift-transformers 1.3.0 (`Tokenizers`, which the tokenizer macro expands
to), and needs Xcode 27 with the Metal Toolchain component
(`xcodebuild -downloadComponent MetalToolchain`): with an older SDK the
adapter compiles out and the MLX section silently never appears, which is
why both release jobs run on the `xcode-27` image. The deployment targets are
the package's floor, iOS 17 and macOS 14 — the app's, not just the
feature's. The macOS Runner compiles `AppleFmChannel.swift` by reference, the
way iOS compiles `RemindersShared.swift`.

Still owed: the licences MLX and swift-transformers ship, on the About page.

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
model is given. Both binds are made in `ish_session_init`, before the shell's
working directory is opened; a bind that does not land is logged and the
shell starts anyway.

The guest has one mount table for every session, so `/root` names **one
project at a time**. The data-dir bind is made once per process; the
workspace bind is made again whenever a session asks for a different
project. `IshShell` decides when that may happen (`_claimHome`): a command in
another project closes the bound project's idle sessions — their next
command starts cold, at the chat's own directory — and the bridge unmounts
the old `/root` (or, where a dying shell still holds it, shadows it with the
new one); a session or one-shot of the bound project still running makes
the other project's command fail with a "run this again" rather than move
`/root` under it. Chats of one project share `/root` freely. Per-project
guest paths were the alternative, and were not taken: `guestRoot` is one
value every caller (prompt, file tools, composer) reads without a project.

The rootfs itself is mounted once per process, at the first command. A Linux
installed where none was reaches the next command; a different one picked,
or the same one reinstalled, after the guest booted takes a restart —
`IshShell` refuses a command whose rootfs is not the one it booted with and
says so, and a reinstall in place is not something it can see. The fakefs root is mounted by
`mount_root(&fakefs, rootfsDir/data)` in `ish_bridge.c`'s `ish_boot`, the
way the app's own boot mounts `<root>/data` (`fakefs_mount` asserts the
source ends in `data` and derives the sibling `meta.db` from it).

iSH's `iosfs` (`mount -t ios`) is the mechanism for a user-picked external
folder, the Files-app picker a `UIDocumentPickerViewController` presents. It is
not used here: the agent's workspace is the app's own data dir, which needs none
of that. It is reserved for a future optional feature, and reusing it would mean
substituting Entoli's own view controller for the `currentTerminalViewController`
iSH's shell expects as the picker's presenter.

**What the app keeps read-only stays read-only in the guest.** A chat's
`resources/` and the skills and agents directories — `Shell.start`'s
`readOnly`, the one
list the backend builds for every shell — are bound read-only at their own
host paths (`bind_read_only`, through `ish_session_init`'s `read_only`), over
the data-directory bind
that already reaches it: the longer mount point wins the lookup. Upstream
records `MS_READONLY_` and only ever shows it in `/proc/mounts`;
`tool/ios/ish/patches/read-only-mounts.patch`, applied by `build.sh` to the
submodule's working tree, makes the generic filesystem layer refuse a write,
create, unlink, rename, link, mkdir, rmdir, `chmod` or truncate through such a
mount with `EROFS`. The host's modes refuse most of that already, since a
realfs mount calls the host's own `open`; what the mount adds is `chmod`, which
the owner may always do and the guest's root otherwise would. Checked with
`clang -fsyntax-only` against the pinned tree; nothing here runs iOS, so the
behaviour is untested on a device.

## Triggers

iOS refuses the process wake every other scheduling clock is — AlarmManager,
launchd — and a scheduled local notification runs no code. What the platform
does have is the due-moment notification, and that is what the clock is:
`IosReminderAlarms` (`lib/data/local/ios_reminder_alarms.dart`) behind
`agent_chat/reminders` and `RemindersPlugin.swift` — the arm, cancel and
prune; the notification half (posting, permission, the tap route, the
present policy) is `macos/Runner/RemindersShared.swift`, one file both
Runners compile, the iOS project referencing it across the tree. iOS keeps
64 pending requests and drops the rest silently, so an arm that lands at the
limit says so in the device log. A one shot or a timer arms
a `UNTimeIntervalNotificationTrigger`; a repeating schedule arms a
`UNCalendarNotificationTrigger` on the repeat's components — wall-clock
anchored and coalescing what a sleep swallows, the property the `calendar`
parameter of `ReminderAlarms.schedule` exists for launchd's sake. The arm
carries the trigger's label and chat id, because the notification's title and
tap route are fixed at arm time: nothing composes them later, there being no
process to compose them in.

`schedules` answers true — the system clock does deliver the moment with the
process dead — which is also what arms `ClockKind`'s diff. The turn itself
runs at the next open: the launch catch-up every missed fire already lands
in, worded "Ran late" where the wait was long. A tap of either notification
is a launch: `didReceive` stashes the chat id the pendingOpen split holds
until Dart's first `takeOpenChat` drain, the macOS plugin's shape. There is
no fire half — `fired` is empty, `takeFired` answers nothing, `doneFiring`
was holding nothing. `exactAllowed` answers true (there is no exact-alarm
permission to deny; authorization is the one gate and `notificationsAllowed`
asks it), and `canHoldTurn` answers the foreground state: a fire claimed in
the brief window after backgrounding is handed back and re-armed a
notification rather than half-run.

The prune is `getPendingNotificationRequests`: the centre enumerates its own
requests, so `staleCodes` answers the arm codes nothing wants, and `cancel`
clears the code's delivered notification beside the pending one — leaving a
delivered one behind says a trigger is there when its tap runs catch-up to
nothing. Identifiers are namespaced, `trigger.<code>` for an arm and
`chat.<id>` for a completion post, so the stale parse never sees a
completion's.

Coverage is the simulator hand-run — the suite holds no Swift tests, like
voice's receipt elsewhere here was the device's. The recipe: create a trigger
a minute out, background or kill the app and wait for the delivery, then tap
it and watch the catch-up run with the completion notification following.
With the app foreground instead the arm stays quiet — `willPresent` shows
none of it, the app's own clock running that fire a moment behind the
system's — and the completion banner answers.

## Byte Repair in the guest

What a setup can run in here is the guest alone — the "Host" env is no shell
at all, which is the gate iOS's banner asks for — and it installs into the
base Alpine the shell already runs: IshShell builds no per-project rootfs
copy, so `apk`'s installs land in what every chat on the device shares, and
the environment delete takes the workspace and marker but no host tree for
the tools. Import is the one that has no answer at all: the guest's
filesystem is the fakefs, which no host path reaches. ESBMC is the remaining
gap on this platform: the releases publish no i386 asset, so the script
picks the x86_64 zip for an i686 guest and the tail's verification refuses
what lands — a setup still reports it did not succeed even after make and
github-cli installed.
