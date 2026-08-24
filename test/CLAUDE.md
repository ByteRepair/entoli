# Tests

What the suite is built on, and the two or three things about it that are not
obvious from reading a test. Everything about the app itself is in the root
`CLAUDE.md`.

## What is shared

`test/harness.dart` holds `TestApp` — the app over a throwaway data directory
with the backend faked — plus `tempConfig`, `makeState`, the dropdown finders,
and the pumping helpers below. `test/fakes.dart` holds `FakeBackend`, whose
`scriptedEvents` and `hold` drive a turn and whose `scriptedTitle` names a chat,
beside `FakeAttachmentPicker`, `FakeLauncherIcons`, `FakeBackgroundWork`,
`FakeFileHandoff`, `FakeBackupHandoff`, `FakeAppRestart`, `FakeVoice`,
`FakeAssistantLaunch` and `testLibrary`.

`FakeAssistantLaunch` is the assistant gesture, and its two halves are the two
routes a launch takes: `pending` is one Kotlin noticed before Dart was
listening, which is the gesture that started the app, and `launch()` is one
arriving while it is already up. A launch into voice mode wants
`pump(settle: false)` and `pumpUntil`, since the orb never comes to rest.

`FakeVoice` is voice mode with neither a microphone nor a model: `hear` is the
user saying something and `spoken` is what the reply came out as, which is the
pair every voice test is written against. `TestApp.create(voiceModels: …)` is
what is downloaded, and the default is nothing — which is what takes the circle
off the composer. `voiceModelIds` is the pair to install and `voiceModelPair`
the same two with their halves named, so that installing one id and picking
another — which leaves voice mode reading "not ready" and every assertion under
it taking the settings branch rather than failing — is not something a test can
do by hand. `TestApp.pickVoiceModels` picks them, and wants a real clock:
`io(tester, app.pickVoiceModels)`.

`voiceControllerProvider` is auto-disposed — a voice session lives as long as
its page — so a test that only `read`s it gets a controller that is gone by the
next line. `voice_test.dart` holds one `container.listen` per session to stand
in for the page that would be watching, and `leaveVoice` closing that hold is
how a test leaves the page. Anything else auto-disposed wants the same shape.

**The turn-level voice tests are `test`, not `testWidgets`**, for the reason
`chat_controller_test.dart` is: a turn is driven by real futures, and
`testWidgets` runs inside a fake clock where a bare `Future.delayed` only
completes when the tree is pumped. Anything asserting on what a spoken turn
wrote belongs beside them; anything asserting on what is drawn is a widget test
over `FakeVoice` with nothing running.

Downloading runs the real store over `test/data/fake_network.dart`. What is
worth pinning is the shape of what lands on disk — the marker that says a model
is whole, and the nothing a cancelled download leaves behind — and none of that
needs a socket. `FakeNetwork` answers each path with a body in two halves and
holds between them, which is where a test cancels; closing it ends the response
where it got to, because that is what a cancelled download is relying on to
stop. `voice_model_store_test.dart` is the first, `file_local_model_store_test`
adds the checksum — a GGUF that arrived wrong is not kept — and
`file_rootfs_store_test.dart` goes one further by unpacking with the machine's
real `tar`: the execute bit and the symlink it writes are the whole reason the
app shells out to it, and only a real one proves they survive.

`downloads_test.dart` is what the catalogs share rather than any one of them:
the notification a phone gets while the app is off screen, which is the one
thing `Downloads` owns that no page draws. `installing` on both store fakes
holds a download open so there is a mid-flight to assert about, and `failWith`
on the voice one is a download that stops.

`TestApp.create(proot: …, linuxes: …)` is the two halves the Terminal page turns
on — whether this build could run a Linux at all, and which are installed — with
`FakeRootfsStore` behind them. Its `installing` completer holds a download open
so a test can see the row mid-flight. What a command actually runs under is not
faked either: `local_shell_test.dart` builds a `Sandbox` out of `/usr/bin/env`,
which really runs, and `proot_test.dart` pins the invocation itself as a pure
function — between them they are what can be checked about proot on a machine
with no Android on it.

`TestApp.create(localLlm: …, localModels: …)` is the same pair for the On-device
page — whether this build has a server at all, and which models are downloaded.
`FakeLocalLlm.served` is what its tests assert on — one entry per `serve`,
including the ones answered from what was already up, since "it did not start a
second copy" is worth asserting. `installed:` is what the pool would find on
disk, and it is a separate list from what is running for the reason the real one
keeps them apart: every downloaded model is in every picker, and only the ones
asked for are loaded. `ready: false` is a model that will not load, which is the
one failure the page has to draw — and reaching that row now means calling
`serve` in the test, because the settings page no longer starts anything.
`loading` is a completer `serve` waits on after publishing its row, which is a
model still coming up and is where a warm-up sits.

`TestApp.create(prefill: true)` builds a real `LocalPrefill` over the two fakes
it sits between and exposes it as `app.prefill`, since what a page shows of a
warm-up and what stopping one reaches are its own. A page drawing one has a
spinner on it, so `pumpAndSettle` never returns and those tests pump instead.
The prefill's own tests hand `LocalPrefill` an `httpClient`: one that refuses
everything by default, and `_FakeServer` — llama.cpp's stream in two chunks,
held in the middle — where "the prompt was never sent" has to be told from
"nothing would have answered anyway".

What the pool is actually asked to do is `llama_server_test.dart`. `llamaLaunch`
is a pure function there for the reason `proot_test.dart` is one; the pool
itself is exercised over `/bin/false`, which cannot come up — and that is enough,
because a failed load still takes its place in the list, so the eviction order
is testable without a server that answers.

`FakeBackend.runningTurns` is the one thing on it that a scripted turn does not
drive: a scripted turn is over the moment its events are yielded, so
`turn_keep_alive_test.dart` sets the ids by hand and watches what
`TurnKeepAlive` does with them. `abort` takes one back out, which is what makes
the Stop path end-to-end rather than two assertions. What the real one promises
— that a chat stays listed until its event stream has closed, not until the
agent stops — is pinned on `BuiltinBackend` instead, in
`builtin_backend_test.dart`.

`FakeFileHandoff` is which platform the workspace explorer thinks it is on, and
its three named constructors are the three answers — `desktop()` has a file
manager and nothing else, `android()` has the share sheet both ways, `web()` has
a download and a chooser. `TestApp.create(handoff: …)` takes one. The explorer
draws a different toolbar for each, so the platform is the fixture rather than
something to guess at with `defaultTargetPlatform`, which would not change what
`kIsWeb` answers anyway.

`FakeBackupHandoff` is the save dialog and the chooser a backup leaves and
arrives through. What was saved is kept rather than counted, since reading the
zip back is the only witness there is that Export did anything.
`settings_data_test.dart` raises `settleIo`'s `tries` rather than its `least`:
reading and writing the whole data directory outlasts the default cap of real
rounds, and the busy bar animates until it is done — so a run that gave up early
would land on `pumpAndSettle` with a running animation and time out. It reads
the restored chats through a `FileChatStore` of its own rather than the app's,
which caches which project each chat is in and was built before the restore —
the store a restart would build is the honest one to ask.

`FakeAppRestart` counts, and runs the `whileStopped` work it is handed — that
work *is* the restore, so a fake that swallowed it would leave every test
asserting on a data directory nothing had touched. **`AppRoot`'s own swap is not
covered**, and that is a known gap rather than an oversight: `AppSession.start`
reads the machine's data directory through `platform.dataDir()`, which a test
cannot point elsewhere without an environment variable it cannot set, and
pumping the real one would build the real backend and read `rootBundle` for the
prompt library. What is pinned is that a restore asks for a restart, that the
restore happens inside it, and that a refused one does neither.

`heldTurn` is a chat parked mid-turn with one event delivered and the widget it
raises on screen, over a backend whose `hold` keeps the turn open the way a real
one is while it waits to be told something. Everything drawing turn-scoped view
state wants it — approvals and questions today — because the ten lines that get
a chat into that position are the same ten each time, and the second copy of
them was already drifting from the first.

`seedChat` is a chat that is actually in the sidebar, which `createChat` now
is — it writes as it creates, so this is that call and nothing else.
`writeChatTo`
(and `TestApp.writeChat`) is for one that has a conversation in it: there is no
whole-log write on `ChatStore` to reach for, since a log is only ever appended
to, so it writes the state and then appends `recordsOf` the messages — which is
what a turn would have done. It closes each reply with a `turnEnd` as well:
without one the chat reads as a turn the process was killed in the middle of and
is offered to be carried on, which is the point of `finished: false` and a
surprise everywhere else.

`TestApp.create(remotes: …, mirrors: …)` is a chat mirrored from a paired
device — the rows the sidebar's Remotes section draws, and what one of them
reads as when it is opened. Both are provider overrides rather than a faked
`SyncHub`, and the empty default is load-bearing: the sidebar and the chat page
both ask whether a chat is mirrored, and there is no hub in a test container to
ask. What the real controller derives from a live mirror is pinned in
`data/sync/sync_hub_pair_test.dart` instead, over two hubs on a loopback
`ByteChannel` — the only place the handshake, the framing and the resource
chunking actually run.

## The filesystem a test runs on

`tempConfig` is a real temp directory over `fileSystemIo`, torn down when the
test ends. That is what `TestApp` uses by default, and what the store and
repository tests assert against with `dart:io` — the layout on a disk is the
thing under test, so `File(config.stateFile(id)).existsSync()` is the honest way
to check it.

`FakeChatStore` is for the other kind: a test whose subject is *what* was
written rather than where it landed. `TestApp.create(store: …)` takes one, and
its `records(id)` hands back the chat's log directly. The log tests use it
because reading records back off a disk meant polling for them, and a poll
under a parallel test run is a test that flakes — twice, before they moved.
Reach for it when a filesystem is incidental to what is being checked, not to
avoid the pumping below.

`sub_agent_log_test.dart` seeds a killed sub-agent the way a kill leaves one:
`recordsOf` a message with something in it and no `turnEnd` after it. The
message is named after the call, since that is the only id a sub-agent
transcript has. `builtin_backend_test.dart` does the same one level up, where
the subject is the parent carrying it on.

`web_filesystem_test.dart` is the other half. `newFileSystemMemory()` is the
same `FileSystemIdb` the web build runs on, over an in-memory IndexedDB rather
than the browser's, so the browser's chat store, its settings and its
attachments are exercised here on the VM. Two `AppConfig`s over one filesystem
is a reload, which is the property the web build exists for and the only way to
check it without loading a tab.

## Widget tests and the fake clock

A `testWidgets` body runs on a fake clock, and real file I/O only advances
inside `runAsync`. Since the store became asynchronous, awaiting it directly in
a widget test waits forever rather than failing — so anything that reads or
writes through the store or the settings goes through `io(tester, …)`.

`settleIo` is `pumpAndSettle` with real rounds interleaved. Two reasons it
exists rather than the plain call: anything reading the store draws a spinner
until it answers and a spinner is a running animation, so settling on one times
out; and a write started by a tap shows no spinner at all while it runs, so an
idle frame is not evidence that it landed. Hence `least` — a floor of real
rounds that happen whatever the tree looks like. Raise it at a call site where a
UI action kicks off store work the assertion depends on, rather than raising the
default.

`pumpUntil` is the same idea aimed at a finder, for waiting on something to
appear.

`pressBack` is Android's back key, and on its own it proves nothing: it goes
through `handlePopRoute`, straight to the framework, and a real press is only
forwarded while the framework has claimed the key. Whether the app *would*
answer one says nothing about whether it would ever get one — see the back key
in the root `CLAUDE.md` for what that costs.

`frameworkHandlesBack` is the other half, so assert it beside any `pressBack`.
It records what the app sent to `SystemNavigator.setFrameworkHandlesBack`,
newest last, and it has to be installed before the action. Two things it does
that a reader would not expect: it resumes the app, since `WidgetsApp` says
nothing to the engine until there is a lifecycle state and a test starts with
none, and it takes over `SystemChannels.platform` for the test — which is also
`Clipboard`'s and `HapticFeedback`'s, so anything asserting on those cannot use
it as it stands.

Do not reach for the memory filesystem to avoid all this. It was tried: sembast
resolves through timers, not microtasks, so a widget test hangs on it exactly as
it hangs on a disk. `runAsync` is the only answer.

## What the wire is not tested against

Everything above the transport is exercised on a loopback `ByteChannel` —
`data/sync/sync_hub_pair_test.dart` stands two real hubs on one. The rendezvous
under it binds nothing either. What each half of it decides is separated from
the socket that carries it: `SignalingRoutes` is the LAN rendezvous and
`SignalingServer` is that plus `HttpServer`; `RelayRooms` is the relay's
forwarding and `RelayServer` is that plus a WebSocket. So
`domain/sync/signaling_routes_test.dart` and the rooms half of
`relay_signaling_test.dart` drive the shipped decisions directly, and
`lan_signaler_test.dart` puts the real client in front of the real routes over
a `MockClient`, which keeps both halves checked against each other.

**No test binds a port.** One that does is a port on whichever machine runs the
suite, and the well-known one the LAN rendezvous uses in earnest is already
taken whenever an Entoli happens to be running there — which is how this was
found.

What that costs is the socket adapters, and it is worth being plain about:
**neither `SignalingServer` nor `RelayServer` is covered by anything.** The
LAN one is the port it binds and its fallback to an ephemeral one, and the
translation of a `SignalingReply` into an `HttpResponse` — headers, status,
body, and the 500 an exception turns into. The relay one is the WebSocket
upgrade and `_SocketPeer`; `RelaySignaler.connect` is uncovered for the same
reason. Master ran both halves over a real socket and valued exactly this;
what replaced it checks the decisions on both sides of the wire and takes the
wire itself on trust. A change to either adapter is a change nothing will
catch, so read it twice.

Nothing else dials. `testSyncHub` hands the hub a `FakeRelaySignaling` unless
a test names its own, so a `syncRelayUrl` in a settings fixture is a string
the page reads rather than a host to look up. It used to be a real dial: the
Sync page's relay test resolved `relay.example.com`, and whether it passed
depended on how fast that failed.

**The WebRTC data channel itself has no automated coverage**, and cannot have
any under `flutter test`: `flutter_webrtc` is a native plugin, so a peer
connection needs an engine with the plugin registered and the Dart VM has
neither. It is confirmed by hand, between two running instances.

That gap has already cost two bugs that every loopback test passed — the frame
header read through `frame.buffer`, and the hello exchange subscribing after
it sent. Both are written up in `lib/data/sync/CLAUDE.md`; both would have
been silent again. Anything changed in `framing.dart` or in `SyncHub._establish`
is worth confirming between two instances before it is believed.

## The live test

`test/live/builtin_live.dart` drives a real provider through the production
path. It deliberately does **not** call
`TestWidgetsFlutterBinding.ensureInitialized()`: that installs an `HttpOverrides`
answering every request with a 400, which is the whole of what a live test is
for. That rules out `rootBundle`, so it copies `assets/prompts/` off disk
instead of using `BundledPrompts`. Not a `_test.dart` file, so `flutter test`
skips it.

## Odds and ends

`ModelPicker` is tested directly in `model_picker_test.dart` rather than through
both settings pages, since it owns every rule about the provider/model pair and
they only say where the values come from.

`openCategory` is the settings page's sidebar. A test window is narrower than
`navBreakpoint`, so a category there is a page pushed over the list rather than
a panel's selection — the helper goes back first when the bar is not the list's,
which is what lets the same call work at either size. Every category needs it
now, General included: narrow, the page opens on the list and nothing else.
`pumpSettings` is that plus the pump, and it takes the category rather than
defaulting to one: the two settings test files wanted opposite defaults, which
made the same call mean different pages depending on which file was being read.

`useWindow` is a window size for the length of a test, reset when it ends. Any
test either side of `navBreakpoint` needs one, and a copy that forgets the reset
breaks a *later* test rather than itself.

`TestApp.pump` supplies the `MaterialApp` itself, so nothing pumped through it
can say anything about the app's own theme. `theme_test.dart` pumps
`AgentChatApp` directly for that, and is the only place the real one is built.
Its `brightness` is for the few widgets that pick a colour per palette instead
of reading one out of the scheme — a code block's token colours are the only
ones so far, and they are wrong in exactly one direction, so both are asserted.

`enabled` is whether an icon button would do anything, over `buttonTipped` where
one is named by its tooltip. A dead button is still drawn and still hit by a
tap, so a test that presses it and asserts nothing happened cannot tell disabled
from broken — the callback is the only witness there is.

A reply still being written ends in a caret, and a caret is a `WidgetSpan`, so
its placeholder is part of what that span reads as: `find.text` will not match
the words even with `findRichText`, and those tests use `find.textContaining`.

`clipboard` collects what the app copied. It takes `SystemChannels.platform`
over for the test the same way `frameworkHandlesBack` does, so a test wanting
both wants one of them — which is why neither is written out per file.

`link_opener_test.dart` fakes the webview at the platform interface rather than
through `TestApp`: `webview_flutter` has no implementation on a test host and
`WebViewController()` throws without one, so the test sets
`WebViewPlatform.instance` to a fake whose navigation delegate it then fires by
hand. That is where `webview_flutter_platform_interface` in `dev_dependencies`
comes from — the app-facing package re-exports the creation params but not the
classes a fake has to extend. The fake stays in the one file that wants it. Its
`androidTest` sets `debugDefaultTargetPlatformOverride`, since the in-app
webview is Android's alone, and undoes it inside the body: flutter_test checks
that variable before a tear-down runs.

A test that writes `settings.json` has to go through `config.documents.write`,
not the file: the app reads settings from the synchronous copy `Documents`
holds, and a file written behind it is not seen. `seedSettings` is that write,
and is deliberately not awaited: the copy is updated on its first line, so a
load on the next one already sees it, and awaiting real file I/O from a
`testWidgets` body hangs on the fake clock.

The composer's keyboard is asserted as `tester.testTextInput.isVisible` rather
than as which node holds focus. The rule the composer keeps is about the
keyboard, and the field has no `FocusNode` to reach for anyway.

Where the caret is the subject rather than the keyboard, `holdsCaret` asks the
`EditableText` inside the field — which is also what a `SelectableText` is built
out of, so a reply answers the same call. `softKeyboard` is the keyboard itself:
the view insets, which are all the platform ever says about one. `TestApp.pump`
wraps what it pumps in `FocusFollowsKeyboard` because `main` does, so a page under
test answers a keyboard closing the way the app would.
