# The macOS half

## Why no sandbox

The one thing this platform was not going to get for free is App Sandbox. The
agent's contract is commands on the machine, exec'd with `Process.start` —
`bash`, `git`, whatever the user has. Under App Sandbox that entitlement soup
must all be written down before the first launch, and nothing about it can be
requested as the agent asks: entitlements live in the code signature, widening
the sandbox at runtime means re-signing, and a denied path is a failed
`Operation not permitted`, not a dialog — Powerbox grants exist only where the
app itself asks with an open panel first. Sandbox or not is therefore the
decision the rest follows, and it came out unsandboxed, which is also what
every agent that ships runs on a Mac does: the app is not sandboxed; the
permissions are the app's own approvals; the OS-level isolation anyone has is
a per-command child sandbox built by the helper. That third is Seatbelt:
`SeatbeltSandboxHelper` (`lib/data/local/seatbelt.dart`) prefixes each confined
command with `/usr/bin/sandbox-exec` and a profile of the turn's grant, in the
slot `platformDriver` keeps for Linux's Landlock helper. `sandbox-exec` is
deprecated and still works; it is probed once, and where it will not apply a
profile a confined command is not run. A Mac App Store build, being under App
Sandbox, could not apply a second profile, and would be `appSandbox` the way
the phones are.

## The entitlements

Both `DebugProfile.entitlements` and `Release.entitlements` are generated files
reduced to almost nothing: Release keeps only the microphone and Apple
Events, which hardened runtime otherwise denies (see "The DMG"), and
DebugProfile only
`com.apple.security.cs.allow-jit`, since a debug build runs the VM with a JIT
and a future hardened-runtime debug signing would want it. Signing under
hardened runtime with those two entitlements is the release story: `make-dmg.sh
--sign` does it and the sandbox never re-enters through the signature by
accident. The Mac App Store — which requires the sandbox — is planned for
when enrollment happens, as a second entitlements file (`app-sandbox`,
`network.client` + `network.server` for the sync hub,
`files.user-selected.read-write` for a workspace grant made once per project)
behind an Xcode configuration of its own, not as a fork of this one. That
build re-enters the Powerbox territory deliberately, since a MAS archive
cannot ship without it.

The deployment target is 15.0, iOS 18's year, so the native UI is written
for one generation of SwiftUI on both (see "Liquid Glass" in
`lib/ui/AGENTS.md`); it is above mlx-swift-lm's floor of 14. FoundationModels
is weak-linked in the Debug and Release xcconfigs, since 15 does not carry
it.

## What a command runs on

The host, and that is all. No proot — W^X is Android's problem and the bundled
tools are that platform's answer to it — and no rootfs: `deviceAbi` answers
null here, which is what hides the Terminal
page's catalog. A macOS turn is a Linux-desktop-with-no-Linux-installed turn:
`LocalShell`'s host driver, the machine's real `HOME`, the user's own tools on
PATH. The login-PATH capture covers it the same way (`$SHELL` as a login
shell, macOS's zsh on the list).

Byte Repair's setup is the one thing that installs onto this host rather than
into the app: Homebrew's `esbmc` formula, and make and gh where missing,
linked into `<cacheDir>/byte-repair/bin`. ESBMC's own mac release links
Homebrew's libraries by absolute path and ships none of them, so nothing else
starts here. Homebrew itself is the user's to install, its installer wanting
sudo; see "Byte Repair's environment, in five variables" in
`lib/data/local/AGENTS.md`.

## The menu bar

The app's menus — `appMenus`, see "The menu bar" in `lib/ui/AGENTS.md` — are
`entoli_menu`'s SwiftUI commands, added to what macOS puts in the menu bar
itself. The first menu is the app's,
titled by macOS with the app's name. About opens Settings > About rather than
the standard panel, so it is the page iPadOS's About opens as well.

Because the bar is always there, the sidebar does not draw Profile,
Marketplace and Settings — `menuBarAlwaysShown` is true here alone.

Window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing`, in
`applicationWillFinishLaunching`): the app has one window, and AppKit would
otherwise add Show Tab Bar and Show All Tabs to the View menu.

Two SwiftUI traps, both from Dart's menus arriving after launch. A `Window`
app's File menu is made only if its group has something in it when the bar
is first built, so a blank item holds the place until Dart sends. And SwiftUI
fills a menu when it is opened, while a shortcut finds only what is filled,
so a key-down monitor fills them all before every ⌘ chord; without it no
shortcut fires until its menu has been opened once.

## The native shell

**The Runner is a SwiftUI app.** `Launch` (`AppDelegate.swift`) is `@main`
so the model host can fork before anything of AppKit loads; everything else
is `EntoliApp`, one `Window` showing `FrontendView` from `entoli_glass`, a
unified toolbar and the menu bar as `.commands`. The delegate, through
`@NSApplicationDelegateAdaptor`, is still a `FlutterAppDelegate` and owns the
one `FlutterEngine`, set up the first time anything asks for its view — the
window's content or `applicationWillFinishLaunching`, whichever comes first,
so `app_links` has its URL handler in place — with the plugins and the
channels in `Channels.swift`. The wake and quit rules stay the delegate's:
a wake launch hides the app once launched, an activation unhides it, and
SwiftUI reopens the window from the Dock. There is no `MainMenu.xib`.

The window shows the launch colour until Dart says which frontend the core
picked, then Flutter's view alone or the shell, whose toolbar and sidebar
wait for the app proper to be up (see "The native shell" in
`ios/AGENTS.md`).

The sidebar is a `NavigationSplitView` column, which on 26 floats over the
detail: the Flutter view runs under the toolbar and the composer and never
under it. The window's appearance is `NSApp.appearance`, not the window's,
since a popover, a menu and a sheet are windows of their own. The menu bar
stays Flutter's, and the native composer takes its own editing keys — see
"Where the platforms differ" under "Liquid Glass" in `lib/ui/AGENTS.md`.

## Shortcuts

Entoli's actions in the Shortcuts app, and through it Siri and Spotlight, on
macOS and iOS alike. **The actions are Dart's; Swift is only their face.**
`Runner/EntoliIntents.swift`, which both Runners compile (the iOS project
references it here), holds the App Intents — making, finding, opening and
asking a chat; reading its reply, its turn's status and its artifacts back;
stopping its turn; adding files to a workspace; renaming, pinning, moving and
deleting a chat; creating and listing projects; voice mode; and running any
of the app's commands — the entities they pass (a chat, a project, a
command, a reply, a turn status), and `IntentBridge`, the one way any of them
reaches Dart: `perform` on `agent_chat/intents` with an action's id and its
arguments. Nothing in the Swift decides anything, so the rules have one home
and the tests reach them.

An intent can be what launched the app, and a call sent before Dart listens
finds nobody to answer it. So Dart says `ready` once its handler is in
place — `listenForIntents`, in `main` after every port is bound — and the
bridge holds each call until it has heard that, a minute at most. A new
engine is not ready until its own Dart says so.

The Dart half has two subsystems behind one boundary, and they are kept
apart on purpose. **`IntentAction` (`domain/intent_action.dart`) is the
boundary's own type**: an id that a saved shortcut names, so never renamed,
and a `perform` that decodes its own arguments (`IntentArgs`) and encodes its
own result. `IntentRegistry` looks an id up; `IntentChannel`
(`data/local/`) is the wire. Neither subsystem knows the boundary exists —
each is adapted to it:

- **Chats** are `ChatIntents` (`domain/chat_intents.dart`), a typed service
  with one `ChatIntentAction` per operation adapting it. It runs with no
  screen, so an action arriving on a background launch still finds it, and
  reaches the UI only through three ports the UI implements: `ChatPresenter`
  to show a chat (the selection's `reveal`), `ChatEditor` for the writes
  behind a chat's row menu (`ChatEdits`, which that menu's dialogs call too,
  so a rename from Shortcuts updates an open chat's title bar the way one
  from the sidebar does), and `TurnControl` for a turn's status and stop,
  answered by the chat's controller where one exists and by the backend
  where none does — never by building one.
- **Commands** are the app's `AppItem`s, every one of them, as
  `command.<name>` — the enum's name being the id it already promises never
  to change. `CommandIntent` runs one through `Commands`, which needs the chat
  pane's context, so `AppShell` attaches a `CommandScope` while it is
  mounted; a command that arrives during a launch waits a while for it. The
  list Shortcuts offers is asked of Dart (`commands`), so a command added to
  the enum is offered with nothing in the Swift changed.

A shared base class over the two was weighed and refused: a command takes no
input, acts on what is on screen and returns nothing, and a chat operation is
the opposite on all three, so a base would hold an id and nothing else, its
generics erased at the one place it is used. What they do share is
`Availability` (`domain/availability.dart`) — whether a thing can be done
now, and why not — which `Commands` answers for the menus (who read only
whether) and a refusal carries to Shortcuts as the sentence it shows.

What an action may not do is decided here, not by the shortcut. Only this
device's chats are listed or driven — a mirror's are its home device's. A
turn goes through `TurnSender`, as a trigger's does, the turn the user
sees on opening the chat, under the chat's own settings: an action never
loosens what the agent may do, since a shortcut's input can be anything it
was handed. So a turn that stops for an approval holds a waiting shortcut
until someone answers it in the app. A project still waiting on its setup
step refuses rather than starting a turn that cannot run. Delete asks
before it does anything, in Shortcuts' own confirmation.

Files cross as paths, not bytes. Add Files writes each one to a folder of
its own under the temporary directory and hands Dart the path, which
`IncomingStaged` moves into the workspace through `writeIncoming` — the
share target's route, `safeRelativePath` included, since the name came
from another app. Get Artifacts goes the other way: each artifact is packed
whole by `readArtifactZip` into a temporary zip, its page and the files
beside it together, and Swift hands Shortcuts the file. Voice mode is not an
intent of its own underneath: it is `Destination.voiceMode`, which the Chat
menu has too, and Start Voice Mode runs it.

The Dart half is covered by `chat_intents_test.dart`; the Swift, like the
rest of it here, by hand. On iOS a background launch gets
seconds, not the minutes a turn can take, so Ask with Wait for Reply is a
foreground affair there; with it off the turn is left running, and the
completion notification says when it ends.

An ad-hoc signed build — what `flutter build macos` makes on its own — lists
every action in Shortcuts and runs none: `linkd` identifies the app by its
team id and, finding none, never connects (`Unable to get teamId` in the
system log, then `openApplicationAndConnect failed`), running or not. The
release's Developer ID signature carries one; a local build tried against
Shortcuts wants signing with a team identity first.

## Closing the window during a turn

The agent runs in the app's own process, so the window's close — which quits
the app, its one window being its last — would kill a turn under way. While
one runs (`BackgroundWork.running`, which `TurnHold` in
`MainFlutterWindow.swift` answers on `agent_chat/background`),
`applicationShouldTerminateAfterLastWindowClosed` says no: the window closes,
the app stays, and the Dock says it is running in the background. Clicking
the icon (`applicationShouldHandleReopen`) or any activation brings the
window back. The decision is the delegate's rather than the window's close
because the native shell's close button closes the window without
`performClose`, which an override there never saw. Cmd-H is an ordinary
hide, and Cmd-Q quits at once, turn or no turn.

**One rule ends a session nobody is watching**, `AppDelegate.quitIfUnwatched`:
nobody has activated the app since it went unwatched (`watched`), no turn is
running, and a wake's own work has drained (`wakePending`). A wake launch
starts unwatched and a close during a turn makes it so; an activation, the
one signal for both, makes it watched again. The end of the last turn and
`doneFiring` each ask, so neither quits under the other's work — a wake's
drain no longer ends a Shortcuts turn started in the same session. A
Shortcuts launch is not unwatched: it is the system's to end, below.

The same hold disables automatic and sudden termination: a Shortcuts action
launches the app hidden in the background, and once the action returns —
Ask without Wait for Reply returns at once — `linkd` lets go of it and asks
for it to be ended if appropriate, which a running turn makes it not.

## Waking for a trigger

**The model the pieces below implement:** `reminders.json` is the only truth,
and launchd jobs are projections of it — one per request code under the
store's own prefix. Every actor converges the projection back to the truth.
The app, at every watch build: scheduling what is armed, cancelling what is
not, pruning what an earlier launch has left behind, and firing through its
catch-up everything overdue, whoever started the session. The job, whose
single line wakes the app with the store named and takes itself out when its
binary is gone — an uninstall having no writer to prune anything. And
launchd, loader and ticker alone: it bootstraps the directory at login, runs
intervals, re-runs a job whose program is gone into a nonzero exit forever,
and never janitors a third-party plist.

The schedule half is launchd, one user launch agent per request code under
`~/Library/LaunchAgents/` — `RemindersPlugin.swift` writes it and boots it
through `launchctl bootstrap gui/<uid>` (raw plists, not `SMAppService`, which
wants its plist inside a signed bundle's `Contents/Library/LaunchAgents/`
where a per-code runtime rewrite would break the signature). The label
carries the bundle identifier plus the data directory the jobs serve, Dart
handing it per call — the debug leaf, an `ENTOLI_CONFIG` scratch and the
installed copy each get their own namespace, so no prune ever sees a job
that is not its store's. The job's whole
business is one line of shell: export the store the jobs were armed for,
then spawn the bundle's own binary detached with the wake argument and exit.
The exit is load-bearing twice: launchd's tracked instance is the shell
alone, never the app — teardown of a service is SIGTERM to its tracked
instance and then SIGKILL (`launchd.plist(5)`'s `ExitTimeOut`) — and the app
boots this label out all the time (every diff, every cancel, the prune), a
wake that exec'd itself dying at its first diff's bootout, before any fire
ran; and the app outliving a job that has died is `AbandonProcessGroup`'s
work, without which the detached spawn's process group dies with the shell.
The export is
load-bearing: a job runs under launchd's environment, which is not the
environment the app that armed it ran under, and the wake re-derives the
data directory from what the command line says rather than from wherever
launchd's own environment points. The spawn goes to the binary directly and
never through `open`, for a reason worth keeping: launch services defers the
start of backgrounded `-g` launches, sometimes indefinitely — the process
idles on its AppKit runloop with no nib load and no Dart — and a hidden
`-j` launch never started an engine at all on this host, while a direct
spawn starts Dart every time. What `open` would buy is one-instance activation,
which the Runner answers itself: a wake session that finds another instance
of the bundle id running the same executable quits before the engine is
built, the running copy's own timer being what fires its due anyway; a
different copy under the same id (a debug build) serves another store and
does not count. The line also exports `ENTOLI_WAKE=1`, which is how the
app's startup knows to skip the update check a wake has no business running. A repeating
schedule arms launchd's own calendar form — `StartCalendarInterval`, the
hourly its minute and the rest their hour, the weekly its weekday and the
monthly its day — wall-clock anchored, surviving DST the way the source's
arithmetic does, and coalescing what a sleep swallows, launchd starting the
job on the next wake; the man page promises an interval arm exactly the
opposite ("if the system is asleep during the time of the next scheduled
interval firing, that interval will be missed" — and the count is awake
time, the clock a kqueue one, so a sleep inside a countdown pushes its tick
late besides). A one shot or a timer has no calendar shape — launchd has no
form for an arbitrary moment either — so it arms a `StartInterval` counted
from the job's load, and what a changed interval is, is a bootout, a
rewrite and a bootstrap — the bootstrap retried a few times on exits 5 and
37, launchd's answer while the bootout it follows is still tearing the old
service down, and every launchctl call made on a serial queue of the
plugin's own rather than the main thread. If the Mac misses the moment either way, the fire
lands at the next launch's catch-up, which is what the fire's "Ran late"
wording is for, the same bargain Doze strikes.

That the interval repeats is also the one spurious fire the shape allows: a
one-shot's job is cancelled only by the diff the fire's stamp triggers, so
a turn that outlasts its own interval — a one-minute countdown with a
several-minute turn — finds launchd re-running the job again after the
session has quit. What comes back is a wake whose catch-up finds nothing,
which prunes the job and quits; bounded at one extra launch per such fire,
and invisible for every schedule whose interval is longer than its turn.

**A wake is not an opening.** The app hides itself — `orderOut` and
`NSApp.hide` in `MainFlutterWindow.awakeFromNib`, where the delegate and the
plugin register too — because `orderOut` alone loses to AppKit's
visible-at-launch ordering, which re-fronts the window after the nib loads;
the whole-app hide is what the `-j` launch flag would have done and cannot
(relaunching hidden never runs an engine). The drained session quits the
moment `doneFiring` says its work has drained — unless someone activated it,
or a turn is still running, a Shortcuts action's say; both are
`AppDelegate.quitIfUnwatched`, the one rule this shares with "Closing the
window during a turn". `watched` is set by an activation watcher rather than
a delegate override so nothing the framework forwards through is displaced.
The turn the wake ran is the ordinary trigger flow: the clock kinds' catch-up
runs it at watch start, unattended and headless exactly as it runs on an
Android alarm's cold start, and the completion notification's tap opens the
chat — a tap of a notification whose app has quit since launching a fresh
process, whose `didReceive` holds the chat id the way `RemindersChannel.kt`
holds a pending open, until `takeOpenChat` drains it.

**Why `doneFiring` quits: the alternative is a hidden scheduler.** The
in-process timer would happily keep aiming at the next fire forever, which is
not the design — the next fire has a launchd job of its own, and a process
standing hidden between jobs is a second scheduler to keep in step. Triggers
firing during the drain are covered: `doneFiring` is only called when nothing
is running and nothing delivered is outstanding, and the terminate trails the
reply by a tenth of a second.

**No fire half exists on the channel**, again deliberately: launchd's only
power is starting a process, and a running app on this platform keeps its
event loop, so `fired` is empty and `takeFired` answers nothing. The Android
channel's held-pending fire list has no job to do here.

**The prune is the part that keeps the jobs honest.** A trigger deleted or
disabled while the app was closed leaves its plist behind, and a job nobody
wants still wakes the app on the old schedule forever — a wake session whose
catch-up finds nothing, opening and quitting: the zombie. `ReminderAlarms`
gains `staleCodes(wanted)` for exactly this: the manager asks it once per
reload with the union of what the clock kinds armed — the union, not a kind's
own, since two clock kinds share one alarm port and each kind's wanted misses
the other's codes — and cancels each answer, deleting plist and job together.
Every other platform answers nothing, which is why the question can live on
the port. What the prune cannot reach is the app's own removal, so the job
carries its removal with it: launchd never tidies a plist whose program is
gone — each interval re-runs `sh` into a nonzero exit, forever — and there is
no uninstaller to run the pruning, so the wake's command line checks the
binary it was written for first and takes its plist and its service out
itself when the check fails. Nothing is left behind after an uninstall, and
nothing needs a hand.

## The model host

The on-device models — MLX's text models and sherpa-onnx's voice — run in a
second process, `entoli-models`, not in the one that draws the window. The
GPU interleaves processes, not the queues of one: MLX encoding in the app's
own process put its work beside every frame the window drew, and a turn on a
4B model held frames for hundreds of milliseconds. Opened as an app of its
own the stutter drops to slight. It is also what keeps a quit during an MLX
turn from crashing — see below.

`ModelProcess` (`lib/data/model_host/`) is what the engines ask for what they
talk to — a `ModelChannel` for the native half, a `Worker` for an isolate —
and they never learn which process answers. macOS gets `HelperModelProcess`;
every other platform `InAppModelProcess`, since iOS cannot start a process
and the rest run their models as a server of their own or on the CPU.

- **It is a helper bundle around this app's executable.**
  `Contents/Helpers/Entoli Models.app` is made by the Runner's last build
  phase (`tool/macos/embed-model-host.sh`): a copy of the Runner binary, an
  rpath to the app's `Frameworks` — the engine, EntoliMLX and the Dart code
  are the app's, not copies — one to the app's `MacOS`, where a debug build
  keeps its code in `Entoli.debug.dylib` beside a stub executable (without it
  the helper dies at launch and a model's load times out after thirty
  seconds), and an `Info.plist` of its own:
  `io.byterepair.entoli.models`, `LSBackgroundOnly`, so no Dock icon and no
  second Entoli to LaunchServices. A copy rather than a target of its own,
  since the host runs the app's own code and a second source list would only
  drift. It is signed before the app's signature seals it as nested code; the
  DMG's `--deep` pass re-signs it with the rest.
- **It is opened, not spawned.** `HelperProcess` asks the app's native half
  (`ModelHostLauncher` in `MainFlutterWindow.swift`), which opens the helper
  with `NSWorkspace` as a new instance, not activated, with
  `entoli-models <socket> <pid>` as its arguments. A child would be this
  app's to macOS, its GPU work scheduled as the app's own. Launched with that
  flag, `AppDelegate.main` branches before AppKit loads anything: no main
  nib, so no window, menu or app delegate, and the helper bundle carries no
  nib at all. `ModelHost` runs a headless engine on `modelHostMain`, the
  app's `App.framework` as its Dart bundle, with `MlxChannel` registered on
  it and nothing else — the system model and every other channel stay in
  the app. A build with no helper — a test, a build
  that skipped the phase — is decided once at the composition root and runs
  the models in-process instead.
- **The socket is the only way in.** A Unix socket in a directory only this
  user can enter, removed once connected, and the host's first frame must
  carry the key handed to it in its environment — which no other process can
  read, where `open --env` put it on a command line any process of the user's
  could. The frames are
  `StandardMessageCodec` messages, length-prefixed (`host_frame.dart`).
- **It runs while something holds it, and five minutes past.** A loaded MLX
  model holds the host from the moment it is made — before the model it
  displaces lets go, so a switch is never idle — until it is unloaded, and
  every voice worker holds it while it runs (`ModelProcess.hold`). With nothing
  held for five minutes the app closes the connection and the host leaves; the
  next ask starts another. The wait is for what comes back — a voice
  conversation picked up again, a model unloaded and asked for — since a
  relaunch is a second a model's load hides and a tap on the microphone does
  not. The app decides rather than the host, since only it knows a load is
  about to arrive.
- **It says what it takes up.** Its `agent_chat/model_host` channel, which
  every host serves beside the channels it is given, answers `footprint`:
  `phys_footprint`, Activity Monitor's figure, since resident size leaves out
  the GPU buffers that are most of a model. The Running models header shows
  it; asking never starts a host that is not running.
- **The host goes with the app, however it goes.** Its parent is launchd, so
  it watches the pid it was handed, and leaves when that exits or the socket
  closes. A host lost is every model in it lost, and every lease on it ends
  with it (`ModelProcessLease.lost`): each MLX model's row says the host quit,
  is not evicted from the next host, and loads again when next asked for. The
  leases end on the process's side rather than their holders', so one held by
  something that never hears is not left keeping the next host from going
  idle.
- **It leaves through `_exit`.** `exit` runs C++ static destructors, MLX's
  Metal device among them, while a generation may still be encoding on
  another thread — the crash every quit during an MLX turn ended in. `quit`
  stops the generations first, bounded at three seconds.

## What is absent, and honestly so

No llama.cpp: the bundled server is built for Android and Linux. The
on-device text models here are MLX's, as on iOS — `MlxEngine`, on macOS 27
where the build links `EntoliMLX` (`tool/apple/mlx/build.sh`, which this
Runner now needs before it links at all). The channels are iOS's own
`AppleFmChannel.swift` and `MlxChannel.swift`, compiled into this Runner by
reference, the second registered only in the model host; below 27 the
handshake answers `mlx: false`, `createLocalEngine` answers `NoLocalEngine`
and the On-device page holds only the voice downloads. See "The MLX models"
in `ios/AGENTS.md`.

The keyring is the file fallback (`KeyringSecretStore` probes a Secret Service
through the session bus, which macOS does not run) and says nothing different
from an absence; nothing crashes over either. Triggers, by contrast, are all
here now — see "Waking for a trigger" below.

## Voice mode

Two engines, chosen per half the way Android's are: Apple's own on-device
pair — `SFSpeechRecognizer` asked `requiresOnDeviceRecognition`, and
`AVSpeechSynthesizer` — behind `Runner/VoiceChannel.swift`, and the sherpa
catalog the other desktops run. `MacosVoice` routes a `macos-recognition` or
`macos-speech` pick to the channel and anything downloaded to sherpa, so
nothing has to be fetched before voice mode works, and a null pick defaults
to whichever of Apple's engines the probe found. The channel is iOS's own file,
compiled into both Runners like `RemindersShared.swift`: what macOS lacks —
`AVAudioSession`, and its way of asking for the microphone — is under
`#if os(iOS)`; a language the Mac cannot hear on-device says so and points at
Dictation, whose download is what supplies one.

**sherpa's microphone is `record`, asked for no echo cancellation here.**
`record_macos` answers `echoCancel` with Apple's voice processing, which turns
the input into a several-channel stream (seven on a MacBook) that its
convert-to-16 kHz-mono step renders as pure zeros: measured, a source peak of
0.099 became an output peak of 0. Silero heard nothing, so every sherpa
listener — a downloaded model or a provider's — was deaf, while speaking
worked. The microphone is shut while a reply is read out, so nothing needed
the cancellation; the channel's own tap never asks for voice processing
either.

What the mic costs is the prompts: `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription` in `Info.plist` are the text TCC
reads — a process asking for speech recognition without the second is
killed — and with Apple Events the only permissions a macOS build asks for.
The release entitlements carry `device.audio-input`, which hardened runtime
otherwise denies; speech recognition needs no entitlement outside the
sandbox.

## The icon

`Runner/entoli.icon` is the app icon's Icon Composer package — the layered
format iOS 26 and macOS 26 render as Liquid Glass — one file for both
platforms (`ios/Runner/entoli.icon` pointing into this tree through a
symlink), its layers generated from `assets/icons/cookie.svg` with the
squircle mask and the shadows left for the system: square layers only, the
glass look is composed by the OS on top. The format's rules, the wiring and
what was verified from where live in a AGENTS.md inside the package itself.
The `prompt` icon has no macOS copy, the way it has no Linux or Windows one.

## The DMG

`tool/macos/make-dmg.sh <app> <output.dmg> [--sign identity]` is the packaging
shape the AppImage's is: staging of app and `/Applications` symlink, one
artifact out. The volume takes the app's name plus Installer — "Entoli
Installer" — so what a user sees mounted reads as the thing being installed,
not the app itself; the staged item inside stays `<Name>.app`. The build
produces an arm64 binary, which is why the asset is `entoli-arm64.dmg` —
ad-hoc signed. **x86_64 is not supported on macOS**: Apple silicon only,
and `EntoliMLX` has no Intel slice. Flutter under Xcode 27 still builds
x86_64 too unless told `flutter config --enable-macos-arm64-only`, and then
fails on the Runner's `import EntoliMLX` — so `pubspec.yaml` sets it for
the project (`flutter: config:`), and CI's macOS job sets it again. An ad-hoc build runs on the
machine that made it; another Mac's Gatekeeper refuses it until Privacy &
Security's Open Anyway is clicked. `--sign` adds the Developer ID identity
under hardened runtime — `--deep` re-signs the engine and plugin frameworks
Flutter left ad-hoc, then the outer bundle is signed again with
`Release.entitlements`, so only the app carries them — and signs the image
itself. Notarization is the distribution step after: `xcrun notarytool
submit` on the DMG, `xcrun stapler staple` the same file, the image being
notarizable whole so the ticket travels inside it.

CI does all of it. The certificate is the Developer ID Application one, a
stored `.p12` (`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`) imported into a
keychain the job makes and deletes, which is unlike the ipa's automatic
signing: the macOS build is `flutter build macos`, not an archive exported
by Xcode, and nothing there asks Apple for a certificate. Only the Account
Holder can create one, and it expires on its own date — a renewal is the
secret replaced, since the job finds the identity in the keychain rather than
by name. Notarizing uses the App Store Connect API key the ipa does
(`APPLE_API_*`). A rejection prints notarytool's log, which names the file.

Hardened runtime takes away what the signature does not ask for, and the
release asks for two things. `com.apple.security.device.audio-input` is the
microphone: without it TCC is never asked and voice mode hears silence.
`com.apple.security.automation.apple-events`, with
`NSAppleEventsUsageDescription` in `Info.plist`, is Apple Events: a command
such as `osascript` that drives another app is attributed to Entoli as the
responsible process, and without the entitlement the send fails instead of
prompting. That one is precaution rather than something seen failing — no
notarized build had run when it went in. `Process.start` and files outside a
sandbox the app does not have are not gated, and neither is the internet.
The local network is, from macOS 15, by TCC rather than the signature:
`NSLocalNetworkUsageDescription` is the prompt the first LAN connection
raises — the same-LAN pairing, sync over the LAN, a provider at a LAN
address — worded as iOS's is.

The window a user's mount opens with comes from committed data, not from any
styling run at package time. One styling session on this Mac — a throwaway
volume laid out by `dmg-layout.applescript` run against it — had its
`.DS_Store` harvested and committed as `tool/macos/dmg-window.dsstore`
(deliberately named nothing like `.DS_Store`: Finder parses the file only in
the volume it is copied into). The background that session bound is committed
beside it: `dmg-background.tiff`, two images per screen scale merged by
`tiffutil -cathidpicheck` from `dmg-background.swift`'s renders — which types
`cookie.svg`'s `bgGrad` stops, and is the authoring tool the pair of them
regenerate from; a single 2x PNG once rendered unscaled and cropped, which is
why the layering. `make-dmg.sh` copies the pair into the staging volume
(`.DS_Store`, `.background/background.tiff`), stages the bundle's `.icns` as
`.VolumeIcon.icns` — found in the bundle rather than named, the `.icon`
package being the authority for that string, with an absent one a line and
not a failure — then creates the UDRW, attaches it read-write once to set the
custom-icon flag (`SetFile -a C`: a headless step, set on the flow's own
mounted volume so it survives the convert — read back verified on the shipped
artifact), detaches, and converts to the shipped UDZO. No Apple events, no
measurement, no math at package time: a CI runner without Finder makes the
same DMG this Mac does. There is nothing to fall back from — the layout is
committed data, so every missing piece is one `[dmg]` line and a failed run.

The capture recipe, for when the look itself changes: stage the app, the
symlink, the background, the icns; create a UDRW; attach it read-write; run
`tool/macos/dmg-layout.applescript` with the design's numbers; wait for the
volume's `.DS_Store` to appear, then copy it to `tool/macos/dmg-window.dsstore`;
detach — the shipped DMG comes from `make-dmg.sh` after that, not from the
capture session. The numbers are the design's, once each, and carry two
Finder facts learned by screenshot: `position` is the point an icon centers
on, not a cell's top-left, so `Entoli.app` goes at {180, 243} and
Applications at {420, 243} with their visual centers on the arrow line 65%
down the artwork (the 17pt ride is the label Finder hangs under each 96pt
glyph); the window content is 600x400 placed at {20, 20} — near the origin,
where every screen finds it — which Finder recorded as `{20, 33}` through
`{620, 463}`, its own margin. And nothing in the artwork is ever drawn in a
flipped space: the texts convert baseline y as `h - y`, and a stroke that
forgets paints 24pt off its row. The window size reasserts itself on every
open; nothing locks it against a user resizing it once open.

All of it stays on hdiutil even though macOS 27 deprecates it for
`diskutil image`, because the new verb is the one that fails intermittently
here — same staging, same command, exit 156 flipping run to run with nothing
public about the code — where hdiutil has been reliable; only its
deprecation notice is swallowed, everything else it says comes through.

## Self-update

The release asset this platform updates itself from is the DMG: the check
mounts it for the `Entoli.app` inside, `ditto`s that beside the running
bundle, and swaps it in by rename — the move a drag-install makes, done under
a running process, with the old bundle restored if the swap fails midway. The
only permission it takes is writability of the directory the app sits in,
which is what the drag needs too; running from the mounted image or from
`flutter run`'s product is caught as not an installed bundle and says so.
See "The automatic update" in the root notes.

## Tests on this host

The suite runs real processes through the host's real shell, so a macOS host
fails fifteen tests before this branch does anything: the recorder
registration (`LinuxRecorder` is Linux's registration), the skills install's
chmod acquire-and-release (the guard is off for macOS deliberately), and the
whole persistent-shell session contract. They are the host's answer, not
regressions, and CI on Linux is what gates the branch. Everything else, and
everything the harness fakes, passes here — the Byte Repair bin directory
and setup gate included: the bin directory is every desktop's now, where
`Platform.isLinux` gated it before.