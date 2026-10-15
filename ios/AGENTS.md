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
in the running app over the VM service.

1. **Install a rootfs and run a command — done, on the simulator.** The
   rootfs half ran end to end (fetch, SHA-256 check, in-process unpack,
   `.complete` marker), and the first command through the guest has since
   run: a `!uname -a` bypass turn and a full agent turn through the `bash`
   tool both came back rc 0 with iSH's own uname string, cwd
   `/root/chats/<id>` — `ish_boot`/`ish_session_init`/`ish_session_run`
   exercised end to end, on record in the chat's `conv.jsonl`. What the
   simulator cannot answer is the device half of it, which is the next item.
2. **The link wiring is xcconfig, not CocoaPods.** `ios/Flutter/Debug.xcconfig`
   and `Release.xcconfig` force-load the right `IshCore.xcframework` slice per
   SDK and name the system libraries (`-lz -lbz2 -lxml2 -lsqlite3 -liconv`)
   the podspec would have carried; there is no Podfile. The framework itself
   is built by `tool/ios/ish/build.sh` (LLVM's clang and lld wanted for the
   vdso; `brew install llvm lld`, both keg-only and not on PATH by default).
   `tools/fakefsify.c` is deliberately not compiled — its `main()` collides
   with the app's; `tools/fakefs.c`'s `fakefs_import` is what
   `ish_fakefsify` wraps.
3. **The runtime path on a real device.** The IshShell/FFI/dispatcher chain
   has only answered on the simulator so far; a device run is the step left
   before a store build.

## The interrupt, and its escalation

`IshShell` delivers a stop on the calling isolate, not through the worker:
the worker parks in a run's poll/read loop for the whole of the command, so
a message to it would queue behind the run it is meant to end. The bridge's
`ish_session_interrupt` is a `send_signal` — marked under iSH's own locks
(`kernel/signal.c`) and honoured by the guest's interpreter thread at its
next scheduling point — so a direct FFI call over the session handle's
address (which `init`'s answer carries to the caller) is the same call,
delivered on time.

Output rides the loop as it happens: every read the worker makes is resolved
by [IshRunBuffer] — the marker parse, the bridge's own C until now — and
what cannot be marker text goes to the run's watch at once, so a command's
output appears in the chat while it runs, the contract the host shell keeps.
The marker's parse is the suite's now (`ish_session_test.dart` pins it over
a fake transport at byte level, splits included), and the reply keeps the
bridge's 64 KiB head cap for what the model sees. The loop still parks
between chunks, which is what makes a message-queued stop wrong.

A guest that ignores the SIGINT is answered a second later by its
escalation, `ish_session_hangup`: SIGKILL into the guest first (the kill
leads, or a dying guest writes into the closing pipe end and the
interpreter dies of SIGPIPE), the read end closed, and one byte dropped
into a wake pipe the run polls beside its stdout. The byte, not the close,
is what returns the worker: a close does not wake a reader parked on the
same fd, and a child the kill did not reach can hold the guest's write end
for its own life — without the byte, a hung-up run would wait on the child
rather than on the second. The run returns "did not complete" and hands
teardown back to the queued destroy.

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
(`IshWorker._ops`), since the bridge's boot and one-time binds are the C
state two isolates could reach at once; the runs stay parallel, each
interpreter being its own task.

## Voice mode

Voice mode is Apple's engines, behind the same `agent_chat/voice` contract
`VoiceChannel.kt` answers on Android — `VoiceChannel.swift` beside the
delegate, and the Dart `Native*` strategies shared with `android_voice.dart`.
Recognition is on-device `SFSpeechRecognizer` only and synthesis is
`AVSpeechSynthesizer`, so nothing said leaves the device and the languages the
settings offer are the on-device intersection.
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
beside the llama pool in `llmEndpoints` (`appleProviderId`, an endpoint
carrying its own client), so the registry, the pickers and a chat's pinned
model see a provider like any other. No server: iOS has no exec, and the
framework *is* the model — the llama pool this build never carried is not a
gap here, for once; this entry is.

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

The simulator cannot run the model (device eligibility fails there, like
the recognizer), so the bring-up is a real device's: the handshake, one
no-tools turn, a tool handoff read back through `conv.jsonl`, then
multi-step against the error map. What the VM does pin is the client's own
protocol over a mock channel — `test/data/local/apple_fm_client_test.dart`:
the streaming, the handoff ending, the history wording, the error map.

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
