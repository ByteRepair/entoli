# A headless server and a thin client

A design, not an implementation. It splits Entoli into a **server** that owns
everything but the window and a **client** that only draws, with one protocol
for the local client and for sync. The decisions it is built around are the
user's and are taken as given; what this document decides is how to meet them.
The questions it could not settle are at the end.

## Why

The agent runs in the window's process, so whatever ends the window ends the
turn. Every platform has grown its own way around that. On master, macOS
hides the app instead of closing it while a turn runs (`TurnHold`, and
`AppDelegate.quitIfUnwatched` ending the session once nobody is watching, from
#485 and #486), and runs wake sessions as a hidden app that quits itself once its fires
drain. Android holds a foreground service and caches a `FlutterEngine` so the
isolate survives its activity. Each answer is correct, and each is a special
case of one missing fact: nothing runs the work except the thing that draws it.

The thing that forces the question is macOS 27's "Running in Background" gray
Dock dot (Apple support article 125671). It appears only when an app is quit
and something it owns keeps running. No public API sets it. A hidden app is
not a quit app, so what #486 put on master cannot show it. Only a separate process can.

## The decisions this is built around

1. **The server owns everything but the window.** Entoli must be able to run
   fully headless. The client displays, and keeps animations, transitions and
   layout. "Thin" means as dumb as a CLI or a web page could be. The only
   client in scope is the Flutter app. A native Swift client may follow, so
   nothing UI-side leaks into the server.
2. **One protocol for the local client and for sync.** The local client is a
   peer of its server the way another device is today.
3. **One "start server" interface.** By default it starts a sub-process.
   macOS starts a background item (`SMAppService`), the one model that earns
   the gray dot. iOS cannot spawn a process, so it starts the server in-process.
4. **The server is the only writer of `<dataDir>`**, `conv.jsonl` included.
   Triggers and sync are server-side.
5. **One client at a time.** No multi-client coordination.
6. **A secret handed over at start**, as `Entoli Models.app` gets its key in
   its environment.
7. **No Pigeon for the protocol.** `packages/entoli_glass` stays as it is.

## What already exists

Three things in the tree already do most of this, at smaller scale.

- **A mirror is already a thin client.** `MirrorChatController` holds no files.
  It replays records it was sent through the same `chatFrom`/`replayTree` a
  reload uses, drives turns by sending `promptSend`, `turnAbort`,
  `approvalRespond` and the edit verbs, and draws the same `TurnSurface`,
  `Composer` and approval banner as a local chat, because both controllers
  implement `TurnDriver`. A paired project's settings, library and memories are
  streamed and written the same way (`RemoteProjectSettingsNotifier`,
  `RemoteMemories`). The local client is a mirror of every chat, with the
  server as the home device.
- **The model host is already a headless engine in a second process.**
  `Entoli Models.app` is the Runner binary under another `Info.plist`,
  `LSBackgroundOnly`, branching in `AppDelegate.main` before AppKit loads a nib,
  running a headless Flutter engine on `modelHostMain`. Its socket is a Unix one
  in a directory only this user can enter, and its first frame must carry the
  key it was handed in its environment. The server is the same shape, larger.
- **`AgentBackend` is already a seam**, with `FakeBackend` behind the tests. It
  stays one, but inside the server (see below).

## The cut line

**The cut is not `AgentBackend`. It is the room.** `AgentBackend` sits below
`ChatController` and `ChatRoom`, and those are what write `conv.jsonl`: the
room appends a turn's records as they arrive, `ChatRepository` owns rewinding,
retitling and TTLs, and `TurnRecorder` decides what a part means on disk.
Cutting at `AgentBackend` would leave the log's writer in the client, against
decision 4, and would leave the room's scheduling, steering, retry rounds and
Omada routing in the one place that has to be thin. It would also leave two
protocols, since sync already cuts higher.

The line sync already draws is the right one: **`TurnDriver` and the
repository's routed reads and writes on one side, everything that runs or
stores on the other.** `AgentBackend` becomes a seam internal to the server,
and `FakeBackend` keeps testing the server's room, repository and protocol
end without a model.

| Server | Client |
|---|---|
| `ChatRoom`, `ChatController`'s room-holding half, `TurnRecorder`, `ChatRepository`, `FileChatStore`, `Documents` | `RemoteChatController` (today's `MirrorChatController`, renamed once it serves local chats too) implementing `TurnDriver` |
| `BuiltinBackend`, the agent loop, tools, shells, iSH, proot | Widgets, pages, routes, animations, layout |
| Settings, project settings, `AppSecrets`, the secret store | Theme built from settings the server sends |
| `PromptLibrary`, skills and agents on disk, `.skill` import, marketplace fetch | Composer's `/` and `@` menus, fed the library over the wire (as `promptLibraryOf` already is for a paired project) |
| Memory store and extraction | Memory page over `memoryCall` |
| Triggers: `TriggerManager`, kinds, `ReminderAlarms`, file watches | Trigger editor |
| `SyncHub`, pairing, WebRTC, signaling server, relay, `devices.json` | Sync pages, the QR, the codes to compare |
| Model catalog, downloads, the local engines, MLX, llama.cpp | Model pickers, download progress |
| `AgentBrowser` (`CdpBrowser`) and its Chromium process | `BrowserCard`: screencast frames in, pointer and keys out |
| Artifacts on disk, backups, migrations, the update's data side | The artifact viewer, file pickers, the save dialog |
| Completion and trigger notifications | Opening the chat a notification names |
| `BackgroundWork` holds (Android foreground services) | Nothing |
| Shortcuts' `ChatIntents` and its rules | `IntentBridge`, forwarding each action to the server |
| — | Clipboard, link opening, app icon, Liquid Glass shell, keyboard, menu bar |

Voice is the one row this document does not settle; see the open questions.

### Where the code goes

`ChatController` and `RemoteTurnDriver` live in `lib/ui/chat/` today because
they are Riverpod notifiers, not because they draw anything. Riverpod's core is
pure Dart, so the server keeps a `ProviderContainer` of its own and the notifiers
that hold rooms move under it unchanged in kind.

The tree gains two roots beside `domain/`, `data/` and `ui/`:

- `lib/server/` — the server's composition root (`serverMain`) and the
  protocol's serving end: the session router, the handlers that answer each
  message family, the room-holding controllers.
- `lib/client/` — the client's connection to its server and the `Remote*`
  providers the pages read.

`test/core/import_graph_test.dart` gains two rules. Nothing reachable from
`lib/server/` imports `lib/ui/`, `lib/client/` or `package:flutter/widgets.dart`
(or `material.dart`, `cupertino.dart`). Nothing in `lib/ui/` or `lib/client/`
imports `lib/data/` except the protocol's generated code and the transports.
The second rule is how "thin" is kept rather than hoped for: a page that wants a
file has nowhere to read one from.

`domain/` imports `package:flutter/foundation.dart` for `ValueListenable`. That
is fine under a headless engine. It is worth replacing with a small listenable
of its own anyway, so that the server's closure has no Flutter in it at all and
a pure-Dart server stays possible (see "What the server process is").

## What the server process is

**A headless Flutter engine running `serverMain`, from the same binary.** The
model host proves the shape on macOS. The server needs plugins: the keychain or
keyring, the reminders plugin, iSH's FFI, `cryptography_flutter`, the Apple
model's channel, the WebRTC plugin. A plain `dart compile exe` binary can call
none of them. A headless engine can, and it runs the app's own `App.framework`
or AOT snapshot, so there is one source list and nothing to drift.

What differs per platform is only where that engine lives:

| Platform | Where the server engine runs | Started by |
|---|---|---|
| Linux | A child process: the same executable with `--server` | `SubprocessServerLauncher` |
| Windows | A child process: the same `.exe` with `--server` | `SubprocessServerLauncher` |
| Android | An app component in its own process (`android:process=":server"`), a service holding a `FlutterEngine` | `AndroidServerLauncher`, a subclass of the sub-process launcher in kind: a separate process, started by an explicit intent |
| macOS | `Contents/Helpers/Entoli Server.app`, a background item registered with `SMAppService` | `BackgroundItemServerLauncher` |
| iOS | A second `FlutterEngine` in the app's own process, on its own isolate | `InProcessServerLauncher` |

Android has no `fork` worth the name for an app, so "sub-process" there means
what Android means by it: a component declared in a process of its own. It is
started by an intent rather than `Process.start`, and otherwise follows the
default launcher's rules.

**Headless on a box with no display** is the one case a headless *Flutter*
engine may not cover. The Linux embedder's headless engine still links GTK, and
whether it starts with no display is untested. The server's closure staying
free of Flutter (above) is what keeps a pure-Dart Linux server open as a later
step: on Linux the plugins the server needs are a D-Bus keyring
(`freedesktop_secret`, pure Dart), `dart:io` and processes. It is an open
question, not a stage.

## The protocol

### One session layer

Today a `LivePeer` is a `SecureChannel` with a `SyncHub` dispatching on its
messages. That becomes general: a **`Session`** is one connection to the
server, carrying the protocol's messages over a `ByteChannel`, with a **role**.
There are two roles.

- **`client`** — the local client. It may send every message.
- **`peer`** — a paired device. It may send today's sync arms and nothing new
  unless that arm is marked for peers.

The role is decided by how the session arrived: through the local transport
with the launch key, or through a pairing route with a handshake. It is then
enforced at dispatch, as sync enforces it today. Each message arm is marked in
the schema with the roles that may send it (a custom option, below), so the
check is generated rather than hand-kept, and adding an arm forces a decision
about who may send it.

A feature that adds a message works for both at once wherever its arm is
marked for both, which is decision 2. Where it is `client`-only (pairing a new
device, the app's provider keys), the schema says so in one place.

### What crosses

The protocol has three shapes of message, all present in `SyncMessage` today:

- **Requests and their reply.** A `requestId` and one `reply`, waited for
  through the echo list sync uses (`_ask`). A refusal is an answer, not a
  timeout.
- **Follows.** Open something, receive a snapshot, then receive changes until
  it is closed: `chatOpen`/`chatSnapshot`/`recordAppend`,
  `projectOpen`/`projectSnapshot`, `subAgentOpen`/`subAgentAppend`. A
  follow resumes from a count rather than starting again.
- **Pushes.** State the server sends unasked: the chat list, `turnState`,
  deletions.

The families, existing ones first:

| Family | Today | Added for the local client |
|---|---|---|
| Session | handshake, `hello`, `ping`/`pong` | `clientHello` (launch key, build id), `superseded` |
| Chats and turns | everything a mirror does | nothing in kind |
| Resources | `resourceRequest`/`resourceChunk`, `.artifacts/`, `.plan/` | uploads to a workspace (Shortcuts' Add Files, the share target) |
| Projects | open, snapshot, prompts, write, create, delete, memory | project rename, move a chat between projects |
| App settings | read inside `projectSnapshot` | `appSettingsOpen`/`appSettingsWrite`; secrets set and deleted, never read back |
| Library | read inside `projectPrompts` | skill and agent create, edit, delete, import, export; marketplace install |
| Models | none | the catalog, `models()`, downloads and their progress, local load and unload, the model host's footprint |
| Triggers | none | list, create, edit, delete; the fire's notification tap routed to a chat |
| Sync admin | none (it is the local device's own) | pairing window, manual invite, codes to confirm, devices, connect, revoke, rename |
| Workspace | none | the explorer's list, read, write, delete |
| Browser | none | a tab's state and screencast frames, pointer and key input, quit |
| Presence | none | which chat the client shows and whether it is in front, so the server knows when a completion is worth a notification |
| App | none | backup export and restore, restart, version, quit-the-server |

**Presence replaces "watched".** `quitIfUnwatched` and Android's sticky engine
each infer from the window whether anyone is looking. The client says so
instead, and the server decides notifications and its own exit from that and
from its work.

### A paired device's chats reach the client through the server

The server is the only thing that holds WebRTC, so a remote device's chats are
mirrored **in the server's RAM** — still never under `<dataDir>`, still never in
a backup — and re-served to the client in the same messages, with the
`ProjectRef`'s device naming where they live. A verb the client sends about a
remote chat is forwarded to that chat's home device, and its echo comes back
the same way. The client has one connection and one way of being told
anything. The repository's routing by chat id moves into the server unchanged.

### Records now, the thread later

A mirror receives `conv.jsonl` records and replays them itself. That is right
for a Dart client, which shares `replayTree`, and wrong for a Swift one, which
would have to port the walk over `siblingOf`, `select`, `rewind`,
`replacesSibling`, `compaction`, `retract` and `callEvent` to draw a chat.
That walk is logic, and logic is what the client is not supposed to hold.

So the protocol carries records first, because sync does and the port is
mechanical, and later adds a **thread view**: the server runs `chatFrom` and
sends the thread being read, as messages and parts with their branch counters,
then sends changes as part upserts, text appends and a whole resend when the
thread changes. A Dart client switches to it when it lands; a Swift client
starts on it. It is the last stage below, because nothing before it needs it.

## The schema and its tooling

**Protocol Buffers, messages only, no gRPC.** `protoc` with `protoc_plugin` for
Dart and `swift-protobuf` for Swift.

Why:

- **Both languages are first-class.** Google's Dart plugin and Apple's
  `swift-protobuf` are both maintained and generate idiomatic types, and both
  read the binary format and the canonical JSON mapping.
- **A `oneof` is the sealed union.** `SyncMessage` is a freezed sealed union so
  that "the dispatcher cannot forget an arm". A generated `oneof` gives Dart a
  `whichBody()` enum, and a Dart 3 `switch` over an enum with no `default` is
  exhaustive, so a new arm stops every dispatcher compiling as it does today.
  Swift's generated `oneof` is an `enum` and its `switch` is exhaustive too.
- **Evolution is defined.** Field numbers and unknown-field preservation say
  what an older reader does with a newer message. Today any change bumps
  `protocolVersion` and both devices must update together; protobuf makes it
  possible to relax that later, though this design does not (see the open
  questions).
- **It frames nothing itself**, which is right here: the framing is already
  sync's, and stays.
- **Custom options carry the roles.** `option (entoli.roles) = …` on each
  `oneof` field is read by a small generator into the dispatch check.

What was weighed and not chosen:

| Option | Why not |
|---|---|
| JSON and freezed, as now | The schema is Dart source. A Swift client would hand-write every type and every change would be found at runtime. |
| Pigeon | Excluded by decision 7, and made for platform channels within one engine, not a socket between processes. |
| gRPC | Brings HTTP/2 and its own streams, and does not run over a WebRTC data channel or `SecureChannel`. The session layer already does requests, follows and pushes. |
| FlatBuffers, Cap'n Proto | Zero-copy buys nothing at these sizes, and Dart support is thin. |
| JSON Schema with quicktype | Unions are weak in both directions, which is the shape this protocol is made of. |

**Tooling.** `protoc` is a native binary, so `tool/prepare.sh` fetches a pinned
release against a SHA-256, the way `tool/android/setup.sh` fetches Qualcomm's
SDK, and CI runs the same script. Generated Dart goes in `lib/protocol/` and,
like every other generated source, is not tracked. The `.proto` files live in
`protocol/` at the root, where a Swift package can reach them too. `buf` is a
reasonable later addition for its breaking-change check, and is not needed to
start.

**Not the disk format.** `conv.jsonl`, `state.json`, `meta.json` and
`settings.json` stay JSON. They are the log and its documents, migrations are
written against them, and a user reads them. While the protocol carries
records, a record or a `ChatState` rides as its JSON in a typed wrapper field,
so the first port is mechanical and the disk and the wire cannot disagree about
what a record holds. The thread view, when it lands, is proto all the way down,
since it is what a Swift client reads.

## Framing and transports

Three layers, each one sync already has.

1. **A transport** gives a `ByteChannel`: whole messages, in order, reliably.
2. **A frame layer** splits a message past the transport's limit and joins it at
   the far end (the `continued` bit), and keeps one send at a time. On a remote
   link this is `SecureChannel`: ChaCha20-Poly1305 AEAD, per-direction counters,
   the type byte as associated data. On a local link it is the same frame
   layout without the seal (`LocalChannel`): the transport is already private to
   this user, and sealing every streamed delta in a background isolate costs
   time for nothing.
3. **The session** decodes protobuf, checks the role, and dispatches.

`SecureChannel` today does both sealing and piecing. The piecing and the send
queue move into a shared base, so both channels piece the same way and the
"frames leave one at a time" rule is kept in one place.

Per platform:

| Platform | Transport | Rendezvous |
|---|---|---|
| Linux | Unix socket | `$XDG_RUNTIME_DIR/entoli/` (0700), else a 0700 directory under the cache |
| macOS | Unix socket | A 0700 directory under `~/Library/Caches/<bundle id>/` |
| Android | Unix socket | The app's private files directory, which both processes share by uid |
| iOS | Unix socket within the one process | The app container. An isolate port pair is the fallback if a socket in-process proves troublesome; the session above is the same either way |
| Windows | Loopback TCP on an ephemeral port, unless `dart:io`'s `AF_UNIX` support on Windows holds up | The port is written beside the key |
| Paired device | WebRTC data channel, unchanged | LAN, relay, manual |

**The socket is also the single-instance lock.** A client starting finds a
socket that answers and connects to it, or finds none and starts the server.
Two clients starting at once race the server's `bind`, and the loser
connects to the winner.

### The secret

The launcher generates 32 random bytes and hands them to the server at start,
in its environment where it is a child (`ENTOLI_SERVER_KEY`), in the intent's
extras on Android, and in the engine's entrypoint arguments on iOS. The
client's first frame (`clientHello`) carries it, and the server drops a
connection whose first frame does not. It is compared in constant time and
never logged.

The server can outlive the client that started it, so a client launched later
must be able to find the key. It is written to a `key` file (0600) beside the
socket. That is honest about what it protects: a process that can read the file
could also reach the socket, so the key adds a check against something that
reaches the socket without being this user's client, such as a sandboxed
process or a stale socket path re-bound by someone else. It does not protect
against the user's own unsandboxed processes. Nothing local can, as the model
host already accepts.

On macOS launchd starts the server, not the client, so there is no environment
to hand the key through. The client writes the key file before it registers or
kickstarts the agent, and the server reads it at start. Checking the
connecting peer's code signature through its audit token (same team identifier)
is the macOS-native addition, and is worth having. See the open questions.

## Starting the server

```dart
abstract interface class ServerLauncher {
  /// A session to a running server, starting one if none answers.
  Future<ServerConnection> connect();
}
```

- **`SubprocessServerLauncher`**, the default. Spawns this executable with
  `--server` and the key in its environment, detached from the client's
  lifetime, then connects. On Linux a new session (`setsid`), so closing the
  terminal or the client does not take it. On Windows not in a kill-on-close
  job.
- **`AndroidServerLauncher`**. Starts the `:server` process's service with an
  explicit intent, which a non-exported service accepts only from this app.
- **`BackgroundItemServerLauncher`** (macOS). Registers
  `Contents/Library/LaunchAgents/io.byterepair.entoli.server.plist` with
  `SMAppService.agent(plistName:)`, whose `BundleProgram` is the
  `Entoli Server.app` helper, and starts it. The helper is built as the model
  host's is: a copy of the Runner binary with its own `Info.plist`
  (`io.byterepair.entoli.server`, `LSBackgroundOnly`), branching in
  `AppDelegate.main` before AppKit loads a nib.
- **`InProcessServerLauncher`** (iOS). Starts a second `FlutterEngine` on
  `serverMain` in this process and connects to it.

### When the server ends

**The server runs in the background only while a turn exists.** While a
client is connected the server is up, as the app is today while its window is
open. With no client connected it stays only while a turn is running, a
trigger's fire included, and leaves when the last one ends. Nothing else keeps
it in the background: not a download, a browser tab, a background job left by
a finished turn, or the sync keep-alive. Those end with the server, as they end
with the app today when it quits. File-watch triggers fire only while the
server runs, which is what they do today while the app runs.

What Cmd-Q does to a running turn is not settled yet; see open question 2.
Either way, the background lasts no longer than the turn.

**One client at a time** is decided at the server: a second `clientHello`
supersedes the first, which is sent `superseded` and closed. A relaunched
client takes over from a stuck one rather than being locked out by it.

**Versions.** The client and server ship in one bundle, so they normally
match. After a self-update the running server is the old build and the new
client meets it. `clientHello` carries the build id. On a mismatch the client
asks the server to quit once idle, says it is finishing a turn while it waits,
and starts the new server when it has gone. The two never talk across builds.

## Sync, consolidated

What changes in `lib/data/sync/`:

- `SyncHub`'s dispatch becomes the server's session router, with peers and the
  client as sessions of different roles. The serving half is unchanged in what
  it does: it is driven by `ChatRepository.changes` and fans out to whoever
  follows a chat. The client is one more follower.
- `SyncMessage` (`lib/domain/sync/protocol.dart`) is replaced by the generated
  protobuf `Envelope`. That is a protocol bump, so two devices update together
  once more, as every arm change has needed.
- The handshake, pairing, the three rendezvous routes, `SecureChannel`, the
  liveness ping and `devices.json` stay as they are, and run in the server.
- The mirror side (`MirrorChat`, `SyncByteCache`) moves into the server, still
  in RAM, and is re-served to the client.
- `MirrorChatController`, `RemoteProjectSettingsNotifier` and `RemoteMemories`
  become the client's only implementations of their interfaces. The local
  `ChatController`, `ProjectSettingsNotifier` and `MemoryStore` sit behind the
  server's handlers.
- `TestApp.create(remotes:, mirrors:, …)` and `establishForTest` are the test
  seams to keep. A widget test stands a fake server on a loopback `ByteChannel`;
  a server test stands a fake client on one, with `FakeBackend` under it.

## Per platform

### macOS

- **The gray dot.** The client gone while a turn runs, with the window closed
  or by Cmd-Q depending on open question 2, leaves `Entoli Server.app` running
  as a registered background item until the turn ends. That is the case the
  Dock marks. Stage 5a proves it on macOS 27 before anything else on this
  platform is built.
- **The window is just a window.** `applicationShouldTerminateAfterLastWindowClosed`
  is true again and nothing overrides it.
- **Triggers wake the server, not the app.** Each launchd job's line becomes a
  `launchctl kickstart` of the server's label, or a connect to its socket if
  the agent is socket-activated. A wake no longer opens a hidden app, hides its
  window in `awakeFromNib`, checks for a second instance or quits when its
  fires drain. The server runs the catch-up as it would on any start, and
  leaves under the rule above. The per-trigger jobs stay, because an
  `SMAppService` plist is sealed inside the bundle and cannot carry each
  trigger's calendar.
- **The model host stays a separate process.** `Entoli Models.app` is an
  external MLX server, and it crashing must not affect Entoli. That holds
  whether the window or the server is what talks to it, so it does not fold
  into the server. The server starts it and holds its leases where the app
  does today, through `HelperModelProcess`, unchanged.
- **Shortcuts.** App Intents are in the app bundle and launch the client. The
  client forwards each action to the server over the protocol. Once an action
  returns, `linkd` may end the client, and a turn it started keeps running in
  the server. Disabling sudden and automatic termination for a turn retires.
- **Notifications** are posted by the server. Whether a notification posted by
  the helper bundle shows as Entoli, with Entoli's icon, needs checking. If not,
  the server asks a client to post it, and starts one hidden when none is
  running.

### Android

The server's process holds the `FlutterEngine` that runs turns, and the
foreground services (`AgentService`, `SyncService`, `DownloadService`) move
there with `TurnKeepAlive` and `SyncKeepAlive`. The UI process holds only an
activity. "Nothing moves into the service" in `android/AGENTS.md` is reversed
on purpose: the server *is* the second engine that note warned against, and it
is safe now because it is the only one that runs anything.

The cached UI `FlutterEngine` that keeps the isolate alive past its activity
stops being needed for turns. Swiping the app away kills only the UI process.

AlarmManager's receiver starts the server process, not the activity. Android
forbids starting a foreground service from the background, so a fire that
needs a hold still has the constraints it has today. "Being the assistant" and
the Files app's `WorkspaceProvider` are unaffected: the latter reads the disk
with no engine and does not write.

### iOS

The server is a second engine in the app's own process, so it is suspended
when the app is, as the agent is today. Nothing about iOS's background budget
changes. What changes is that the code above the transport is the same as
every other platform's. iSH is FFI and runs on the server's isolate. The Apple
model and MLX channels are registered on the server engine, as the model host
registers `MlxChannel` on its own.

### Linux and Windows

The server is a child of the client and outlives it while it has work. On
Linux the process shows as `entoli --server`. The AppImage starts it with
`$APPIMAGE --server`, so an update renamed over the AppImage is picked up by
the next server start. Windows' self-update arms `msiexec` at the client's
exit, so the waiting PowerShell has to wait for the server's exit too.

## Staged migration

Each stage ships alone and leaves the app working on every platform.

**Stage 0: move the room out of `ui/`.** `ChatController`'s room-holding half,
`RemoteTurnDriver`, the turn sender and the keep-alives move into
`lib/server/` without changing behaviour, behind the providers they already
have. Add the import-graph rules for `lib/server/`. Replace `ValueListenable` in
`domain/`. No protocol change, no process change.

**Stage 1: the schema.** Write the `.proto` files for every `SyncMessage` arm,
records and states as JSON wrappers. Add `protoc` to `tool/prepare.sh` and CI.
Port `SyncHub` to the generated `Envelope` and bump `protocolVersion`. Sync
between two updated devices works as before. Nothing local changes.

**Stage 2: the session and the local channel, in-process everywhere.** Add
`Session`, roles, `LocalChannel` and the shared frame base. Run the server
in-process on **every** platform behind `InProcessServerLauncher`, and point the
chat pages at `RemoteChatController` over a loopback channel. The client still
shares a process with the server, so a missed path still works while the
import rules are tightened. The local chat is now driven exactly as a mirror
is.

**Stage 3: everything else over the wire.** One family per PR, each adding its
messages, its server handler and its client provider, and deleting the
client's direct reach: app settings and secrets, library, models and
downloads, triggers, sync admin, workspace, browser, backups. The stage is done
when the second import rule passes: `lib/ui/` and `lib/client/` reach nothing
in `lib/data/`.

**Stage 4: the sub-process.** `SubprocessServerLauncher` on Linux and Windows,
`AndroidServerLauncher` on Android, the presence messages, the exit rule and the
version check. iOS stays in-process for good. The Android foreground services
move to the server process here, and the UI's sticky engine goes.

**Stage 5a: prove the gray dot.** A small test build, before anything else
on macOS is built: an `SMAppService` agent registered from the app bundle,
the app quit while the agent keeps running, and macOS 27's "Running in
Background" dot checked in the Dock. It also records the approval prompt the
user sees on first registration. Stage 5b goes ahead only if the dot shows. If
it does not, the macOS launcher is redesigned before any of 5b is written.

**Stage 5b: macOS's background item.** `Entoli Server.app`,
`BackgroundItemServerLauncher`, triggers retargeted to the server, and the
retirements below.

**Stage 6: the thread view.** The server sends the thread being read rather
than records. The Dart client moves to it, and drops `replayTree` from its
closure. This is what makes a Swift client a client rather than a port.

## What it retires

macOS:

- `TurnHold` and `BackgroundWork.running` on `agent_chat/background`, and the
  close-hides-the-app behaviour of #485 and #486.
- `AppDelegate.quitIfUnwatched`, `watched`, `canQuit` and the activation
  watcher's unhide-and-reopen.
- `wakePending`, `doneFiring`'s quit, the hide in `awakeFromNib`, the
  wake-time single-instance check and `ENTOLI_WAKE`.
- Disabling sudden and automatic termination for a Shortcuts turn.
- The "Closing the window during a turn" section of `macos/AGENTS.md`, most of
  "A wake is not an opening", and "Why `doneFiring` quits".

Android:

- The UI process's cached `FlutterEngine` as the thing that keeps turns alive,
  and its eviction rule.

Everywhere:

- `interruptLiveTurns` on a relaunch from the UI. A restore restarts the server,
  which interrupts its own turns. A client relaunch interrupts nothing.
- `SyncMessage`'s freezed union, replaced by generated code.
- The split in every page between a local provider and a remote one. One
  remote provider is left.

What it does **not** retire: `Entoli Models.app` and `HelperModelProcess`,
`AgentBackend` and `FakeBackend`, the sync
handshake and framing, the launchd trigger jobs, Android's foreground services
(they move), and the "Carrying on an interrupted turn" invariant. That invariant
was that a turn cannot outlive the process running it, and it now reads "the
server process". An open log with no `turnEnd` still means the server died
mid-turn, and a reconnecting client learns from `turnState`, not the log,
whether a turn is live.

## Risks

- **Startup latency.** A cold client must start an engine before it can list a
  chat. The client draws its shell at once and fills it when the first snapshot
  lands, as a mirror's pages already do.
- **Throughput.** A streaming reply crosses a socket per checkpoint, not a
  function call. A loopback Unix socket is far above what a model streams.
  The browser's screencast is the heaviest traffic, and it goes as binary
  frames, which the type byte already separates.
- **Plugins on a headless engine.** Each plugin the server uses must register
  and work without a view. The model host shows it can work. Each needs
  checking once.
- **Two processes to debug.** `logFailure` lines gain the process (`[server]`,
  `[client]`). On desktop the server's log goes to a file under the cache, so a
  user can send it.

## Open questions

1. **What did the earlier refactor session decide?** Its conclusions were not
   found. Anything it settled about the cut line, the schema or the staging
   should override this document where they differ.
2. **Cmd-Q with a turn running.** The answer so far was: "No, this shouldn't
   happen, it runs in the background only while a turn exists." The second half
   is now the exit rule above. The first half can be read two ways. Does Cmd-Q
   still end the running turn, as it does on master, so only closing the window
   leaves a turn in the background? Or does Cmd-Q quit the client and leave the
   turn running in the background until it ends?
3. **The secret on macOS.** launchd starts the server, so no environment
   carries the key. Is a 0600 key file beside the socket, plus a code-signature
   check of the connecting peer, an acceptable reading of decision 6? Or should
   it be a keychain item shared by the app and the helper?
4. **Registration approval on macOS.** `SMAppService` registration can leave the
   item waiting for approval in Login Items, with a system notification on
   first registration. Register at first launch, or at the first turn that
   would be left running?
5. **Voice.** Should the microphone and speaker stay in the client, as the
   user's presence at the device, with recognition and speech in the server and
   audio frames over the protocol? Or should voice run wholly in the server?
   Android's system engines want an activity's context, which argues for the
   client there.
6. **A pure-Dart server on Linux** for truly headless use on a machine with no
   display. Worth a later stage, or out of scope?
7. **Protocol tolerance.** Protobuf could let an older peer ignore a newer arm,
   relaxing "both devices update together". Keep the strict version check, or
   relax it for arms marked optional?
8. **Client-side state.** Is the client allowed any file of its own, for
   window size or the last open chat? Or does all of it live in the server's
   settings, leaving the client with nothing on disk?
9. **Same-host shortcuts.** May a local client open an artifact, a backup or an
    attachment by a path the server hands it, rather than receiving the bytes?
    That is faster, but a Swift client on another machine could not, and it
    would make "local" and "remote" differ again.
10. **Windows transport.** Loopback TCP, or `AF_UNIX` if `dart:io` supports it
    there? This is a spike, not a preference.
