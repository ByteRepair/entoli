# The Android half

## Staying alive off screen

Android kills a process nobody is looking at, and a turn is minutes of a model's
time and a half-written reply. `AgentService` is a `dataSync` foreground service
that says the process is busy; `TurnKeepAlive` starts and stops it from
`AgentBackend.runningTurns`, which is the chats `BuiltinBackend` has an agent
running for. It is a `ValueListenable` of ids rather than a count so that Stop
can abort each one, which is also why there is no `abortAll` — one way to stop a
turn.

**A service per kind, not one for all.** `VoiceService` holds the microphone
while voice mode is listening and `DownloadService` holds a model being
fetched, and both are as much work the process must not be killed in the
middle of as a turn is. They are separate because a service has one foreground
notification and these are different things to stop — and because from
Android 14 the one that holds the microphone has to say so, hold
`RECORD_AUDIO`, and be started while the app is in use, none of which a
`dataSync` service may claim. Everything about *how* a service is held,
stopped, refused and woken is `ForegroundWork`; each one says only which it is
and what its notification reads. `BackgroundWork` therefore carries a kind
rather than a count, and `stopRequests` says which button was pressed —
killing every turn because a download was cancelled is not what the user
pressed. The wording stays in Kotlin for the first two; a download's cannot,
since which model is being fetched is the catalog's and Kotlin has never heard
of the catalog.

The newest is `SyncService`, and it is held for a different reason from the
others: nothing is mid-flight, but a WebRTC channel that no process
running is a channel no longer there. When the screen goes dark the process
freezes, the data channel dies, and a phone's end of a pair goes quiet for the
night — this is what stops that, behind the Sync page's "Keep connected off
screen" setting (off by default; the cost is a wake lock and a notification
for as long as a device is connected). `SyncKeepAlive` (`lib/data/sync/`)
reports the connected peers to it and answers its Disconnect by calling the
same `hub.disconnect` the Sync page's row does — which is what drops the
statuses and releases the service, the notification going when the
connections do rather than when the button is pressed. The count is worded in
Kotlin, the names ride in from Dart the way a download's label does, and the
action says Disconnect rather than Stop — what it ends is connections, not
work mid-flight.

**A swiped notification is put back.** Since Android 14 the user can dismiss
any foreground-service notification, and the service keeps running when it
goes — a swiped sync hold would look exactly like the failure it exists to
prevent, and the Disconnect would be gone with it. Nothing is told of a
dismissal, so `ForegroundWork` polls its own notifications (one array scan a
second, under the wake lock it already holds) and re-attaches the
notification through `startForeground`, silent because `setOnlyAlertOnce`
is on; a legitimate stop never meets the watch, since `stopService` runs
`onDestroy` and the watch dies there. `rePostOnSwipe` is the opt-in, sync the
only service that has; the others would want it eventually, which is issue
#244's.

**Nothing moves into the service.** The turn runs in the app's own isolate, as
it always did; all the service buys is the right for that isolate to keep
running. That is what keeps the invariant of "Carrying on an interrupted turn"
true: the UI that comes back is the one that never stopped listening, not a new
one reading a log. A second engine in the service would have broken it, and
would have had two copies of every session besides.

Two halves, and only together: the service stops the *process* being killed, and
a **cached `FlutterEngine`** stops the *isolate* dying with the activity when the
app is swiped off the recents list. `MainActivity.provideFlutterEngine` builds
one and puts it in `FlutterEngineCache`; `FlutterActivity` already declines to
destroy an engine the host provided, and the delegate runs the Dart entrypoint
only while Dart is not already executing, so a relaunch reattaches to the
running app rather than starting it again. `main` therefore does not run twice,
which is what makes the controllers, the sessions and the settings cache still
be there.

That is also why `onDestroy` throws the engine away again when the activity is
finishing and `ForegroundWork.busy` is false — which counts voice mode too,
since the session it holds is in that same isolate. Cached unconditionally it would be a
permanent change to what "a restart" means: `main` builds the `PromptLibrary`
once and hydrates the `Documents` cache once, and both are documented as picking
up an edit made behind the app's back on the next restart. With no eviction that
restart would only ever come when Android reclaimed the process, which is
nothing the user can do on purpose. So the sticky isolate lasts exactly as long
as the thing that needs it, and closing the app with nothing running gives a
genuinely fresh one next time.

An engine outliving its activity is also why `IconChannel` was pulled out of
`MainActivity` and registered on the engine against the application context: the
handler used to close over the activity, and holding a destroyed one for the
life of a process is the leak this feature would have created. `FilesChannel`
is built the same way for the same reason, and starts everything it starts with
`FLAG_ACTIVITY_NEW_TASK`, which is what an application context needs.

Stopping is one path. The notification's Stop asks Dart, Dart aborts every
running turn, and the emptied `runningTurns` is what then stops the service — so
the notification goes when the work does rather than when the button is pressed.
What made that a second path rather than one was the *record*: `TurnEnd.aborted`
used to be set by `ChatController.abort`, the caller, so a turn stopped from
anywhere else was logged as having finished. It rides on `DoneEvent.aborted`
now, which the backend sets wherever `abort` is reached, and the controller still
sets it before awaiting because a backend that closed the stream without the
event would let `onDone` record the turn first.
`onTimeout` (Android 15 caps a `dataSync` service at six hours a day, and crashes
the app if it lingers) is the exception: it drops the service and leaves the turn
running, since the process is then merely killable again, which is where every
other platform already is.

`POST_NOTIFICATIONS` is asked for in `onCreate` rather than when a turn first
needs it. The service is started from a running turn, and by then there may be
no activity in front of the user to ask through — and a foreground service whose
notification cannot be shown is one the user can neither see nor stop.

The service is started while the app is in the foreground, never later: Android
forbids a backgrounded app from starting one at all. That is free here, because
a turn only ever starts from a tap. A refusal is caught all the same and stands
the service down, since an uncaught one in `onStartCommand` is a crash and the
daily cap can already have been spent.

`runningTurns` drops a chat *after* its event stream closes rather than when the
agent stops, which is the whole of what the seam is for: `_finishTurn` is still
draining the append queue and writing the `turnEnd` record when the loop ends,
and that is the window "When a turn is over" says the process must survive. What
is still not covered is the last few milliseconds of that write — the listener's
queue is the UI's, and the hold is released when the backend's stream closes, not
when the log falls quiet. A lease taken by the writer would close it, and would
be the thing to reach for if a killed tail ever shows up in practice.

Two costs are deliberate. The wake lock covers a turn parked on an approval
banner, where nothing is running and the phone is being kept from suspending for
as long as the user does not answer; releasing it there needs a second signal
through three layers for a rare case, and the six-hour cap bounds it. And the
notification's wording lives in Kotlin, because the port carries a count rather
than the chats — which is also what a notification naming the chat would have to
change. The sync hold is the same shape, minus the parking: it is behind a
setting, so the wake lock it holds is one the user chose.

## The workspaces in the Files app

`WorkspaceProvider` is a `DocumentsProvider`, which puts Entoli in the Files app
and in every picker that asks for a file or a folder — the mechanism a cloud
drive uses to appear there. Exported behind `MANAGE_DOCUMENTS`, a permission
only the system's document UI holds, so nothing queries it directly: an app gets
the URI the user picked through that UI and nothing besides, and
`FLAG_SUPPORTS_IS_CHILD` is what lets them pick a whole workspace rather than one
file at a time.

**Read-only**, because this is the route out and the other direction already has
a better one: a file coming in has to be told which workspace it belongs in, and
"Sharing to Entoli" above is the page that asks. Writing would be
`FLAG_SUPPORTS_CREATE` and `createDocument`/`deleteDocument` beside what is there
rather than a change to any of it.

**The tree is the on-disk layout, not a view of it.** The root is every project,
which is what `projects/` holds; a project's children are its shared
`workspace/` and, named by title, the folder each of its chats works in — those
being folders inside that workspace rather than beside the conversations, so
opening the shared one reaches them too. A workspace is a directory called
`workspace`, so it is named by the word the explorer uses; a chat's is named by
the title in its `state.json`, which lives with the conversation rather than in
the folder named after it.

A document id is either a project — `:` for the root, `:<name>` for one — or a
path relative to the data directory, which is what every file in a workspace is.
Neither can be read as the other: a real path always starts `projects`.
`workspaceDepth` is the whole of what a path can reach — it has to name
`projects/<name>/workspace` before anything under it resolves, so `chats/`, with
`conv.jsonl`, `resources/` and `subagents/` in it, and `settings.json` beside
them, are not in the tree and cannot be asked for. `projectOf` holds a project
id to `AppConfig.projectDir`'s rule for the same reason, and why both are needed
is worth saying: a tree grant lets the app holding it compose ids of its own, so
`:..` is an id that arrives rather than one that was handed out.

Kotlin's `isProjectDir` is Dart's `isProjectName` bar its refusal of `default`:
Dart calls the default project `null` and has no use for the string, where here
it is a directory like any other. It also refuses the directories of the
built-in projects whose workspace is not shared, which is what keeps an
anonymous chat's scratch out of the tree: a chat that must not reach past itself
is not one whose scratch the Files app browses. A built-in that shared its
workspace would be in the tree like any other project, and out of the set. The
set (`UNBROWSED`) is restated in `WorkspaceProvider` beside `DEFAULT`, by hand,
for the reason nothing from Dart is running when this is asked.

A data directory a release has yet to migrate reads as empty here. Migrating is
`migrations.dart`'s and happens the next time the app is launched, so an update
that moves a workspace leaves the Files app showing nothing until then; doing it
from here would be a second copy of that chain with no engine running to check
the result.

Paths are then resolved canonically and checked against the workspace they came
out of, on a listing as well as on an open. The agent's own commands run in these
directories, so a link to the data directory is something it can be told to leave
behind, and following one would hand over exactly what the shape check exists to
keep out of reach.

**Nothing of Dart is running when any of this is asked** — the Files app starts
the process by querying — so the data directory is found with
`PathUtils.getDataDirectory`, the call `getApplicationDocumentsDirectory` itself
makes, and a chat's name is read out of its own `state.json`. Reading those
behind the app's back is safe for the reason the documents are written through a
rename: there is no half-written one to catch. It is also why the layout is read
rather than indexed: a `workspaces.json` beside it would be a copy to keep in
step, and a chat moved by hand would stop being in the project it was moved to.

## Being the assistant

Picked as the system's assistant, Entoli is launched by the gesture that used to
raise Google's — long-press home, or a swipe up from a corner — and opens a new
chat, in the project and the view the Assistant settings name. Android's, and
only Android's.

The manifest half is an `ACTION_ASSIST` filter on `MainActivity` and on the
`.PromptIcon` alias, for the reason the share filter is on both: whichever is
enabled is the only component that can be started, and being the assistant must
not stop working because the user changed the icon. `CATEGORY_DEFAULT` is
load-bearing rather than boilerplate — the role is offered to whatever
`queryIntentActivities(ACTION_ASSIST, MATCH_DEFAULT_ONLY)` finds exported, so
without it the app is not in the picker at all. Nothing else is needed: no
permission, and no `VoiceInteractionService`, which is the other way to hold the
role and is a great deal more than a launch signal.

**The launch is held rather than pushed**, which is the whole of what
`AssistantChannel` does. The gesture is usually what starts the app, and Dart is
not listening for a good while after that — so a launch waits in Kotlin until
`AssistantLaunch.take` asks, and the invoke behind `launched` is only a nudge
for an app that was already up. `FilesChannel` splits a share exactly this way,
and both halves are needed for the same reason, the cached engine included: an
activity whose engine was cached runs `onCreate` but not `main`, so the
first-frame read never repeats and the nudge is what carries that case.

`IncomingAssistant` wraps the app beside `IncomingShares` and is the same shape:
the postFrame read, the stream, and a flag so two gestures do not leave two
empty chats. It selects the project *before* it makes the chat, since
`startChat` and `startVoiceChat` both read `selectedProjectProvider` — which is
also what lets the view setting be nothing more than which of the two to call.
`AssistantView.voice` therefore inherits voice mode's own answer to missing
models: the settings prompt rather than a dead page.

A launch always makes a **new** chat. The gesture is how a conversation is
started, not how one is returned to, and the sidebar is still there for the
other thing.

The settings are app-level, with no per-chat override, for the reason the icon
and the theme are: the assistant is the app's, and the chat it opens does not
exist yet to have an opinion. Their category is drawn on every platform, the way
the voice one is where `Voice.available` is false — the settings are the app's
whatever it is running on, and hiding them would make the file's contents depend
on where it was last opened. `assistantProject` is `null` for the default
project, which is the null `selectedProjectProvider` already uses.

**It holds a name, so it is a weak reference**, and that is answered in two
places rather than one because they answer different halves. `deleteProject`
clears it, beside the `selectProject(ref, null)` already there — the setting is
the other reference to a project that has just stopped existing, and left
written down it is written *back* by the next save, so recreating a project of
that name would silently re-arm it. And both ends read it through
`projectOrDefault`, since a directory can also go behind the app's back: the
field shows `Default` and the gesture lands there, rather than the field saying
one thing while the gesture recreated the directory. One function in
`domain/project.dart` rather than the same test spelled twice, which is what it
was and which had already drifted — one end searched the list with the default
project in it and the other the list without.

## The app icon

Two icons, `AppIcon.cookie` (the default) and `AppIcon.prompt`. The enum's
declaration order is the order the settings page offers them in, so the default
reads first. Each exists
several times over, because each platform wants its own form and they are
checked in rather than built: `assets/icons/*.svg` is what the app draws,
`drawable/ic_<name>_{foreground,monochrome}` over the shared
`ic_icon_background` are the Android adaptive layers named by
`mipmap-anydpi-v26/ic_<name>.xml`, and `web/icons/` is the PWA set. Android
reads no SVG, so its copies are the same path data as a vector drawable, and
editing one means editing all of them — there is no generator. The Apples'
copy is one file for both platforms and the default only: `entoli.icon` under
`macos/Runner/`, the Liquid Glass layers, with `ios/Runner/entoli.icon/CLAUDE.md`
a symlink into it. The cookie's
launcher layers are the exception: `drawable-*/dpi/ic_cookie_{bg,fg}.png` are
`cookie.svg` rendered by `resvg` (`bg` is the gradient and sheen alone, `fg`
the blob and glyphs with their drop shadows, at the five adaptive sizes), so
an artwork edit means re-rendering them the same way — the SVG filters a
vector drawable cannot carry is why they are rasters. The monochrome layer
stays a flat silhouette, a themed icon being a tinted one; the debug build
keeps its black vectors through its own `mipmap-anydpi-v26/ic_cookie.xml`.

The PWA set is the default icon's SVG rendered at each size, and only the
default's — a browser cannot be told to switch, so the other icon has no copy
there. `Icon-*` is the file as it stands and `Icon-maskable-*` is the same file
with the squircle `clip-path` dropped, which is what makes it the full-bleed
square a maskable icon has to be. `favicon.png` is the clipped one at 32.
`Icon-512.png` is load-bearing off the web as well: the AppImage takes its icon
from it, a Linux desktop being no more switchable than a browser. See "The
Linux AppImage".

`minSdk` is pinned to 26 rather than following `flutter.minSdkVersion`, which
is 24. Adaptive icons start at 26; below it every icon needs a full set of
rasters at five densities as well, which was ten files existing only for
Android 7.x. Pinning it is also what let the pre-Lollipop
`drawable/launch_background.xml` go — the `-v21` one it shadowed reads the
theme background instead of hardcoding white, so the splash follows dark mode.

The monochrome layer is not decoration: a themed icon is the silhouette tinted
from the wallpaper, so an icon whose meaning lives in its colour has none there.
The background is one file for both icons rather than one each, since both sit
on the same flat indigo. `AgentService`'s status bar icon is the default icon's
monochrome layer, and it does not follow the setting: a notification is the
app's, and nothing there is per-choice.

`<application android:icon>` points at `@mipmap/ic_cookie`, the default icon's
own resource, rather than a copy under a name of its own — the app-info icon
then gets the adaptive form too, and there is one fewer image to keep in step.

`appIcon` is app-level and has no per-chat override — an icon is the app's, not
a conversation's.

Changing it is two writes, and only one of them is the app's. `setAppIcon`
saves the setting first and then tells the launcher, because the setting is what
`AppMark` draws from: a launcher that refuses still leaves the app showing what
was picked. Android is the only platform where the launcher can be told
anything at all; everywhere else `LauncherIcons.available` is false, the
settings page says the home screen will not follow, and the setting is in-app
only.

Android switches icons by making `MainActivity` the launcher entry and
enabling an `activity-alias` in its place when a non-default icon is picked.
`MainActivity` carries the MAIN+LAUNCHER intent-filter and wears the app-level
`android:icon` (`@mipmap/ic_cookie`); each non-default icon is an
`activity-alias` targeting `MainActivity`, disabled by default. Exactly one
entry is enabled at a time, or the app appears on the home screen twice — so
`IconChannel.kt` treats the default as one entry among the aliases, enabling
the wanted one *before* disabling the rest. An instant with no launcher entry
enabled is one a launcher can read, and it drops the app off the home screen
for good.

`MainActivity` carries the LAUNCHER filter (rather than only the aliases
carrying it) because Flutter's pre-build manifest parse — the fallback when no
built APK exists yet — matches `activity` by exact element name and never sees
`activity-alias`. With the launcher entry only on aliases, `flutter run` after
`flutter clean` fails to find a launch activity and never builds. The aapt2
path (used once an APK exists) does handle aliases, but the fallback has to
work too.

A `ComponentName` is (application id, fully-qualified class), and the halves
come from different strings. The manifest's `.PromptIcon` is expanded against
the **namespace**, so the class name is derived from `MainActivity`'s own
package, while the package half has to be the context's `packageName` — the id
the app is installed under, which the debug `applicationIdSuffix` (`.debug`,
what lets a debug and a release build sit side by side) makes a different
string. Naming the
package half with the namespace makes `setComponentEnabledSetting` throw, and
the Dart side swallows that, so the first version of this silently did nothing
in every debug build.

Not behind a conditional import the way `Shell` is: a `MethodChannel` compiles
everywhere and a platform with nothing answering it throws, which is the same
no-op `available` being false gives. So the app still has exactly one
conditional import — `ForegroundService` is the second channel to be built this
way.

Every channel — this one, `ForegroundService`, `FilesChannel` and
`AssistantChannel` — is registered when the engine is created rather than on
each attach, and holds the application context. That is forced by the engine
outliving the activity: see "Staying alive off screen".

### The debug build's own

A debug build installs beside a release one — its application id is suffixed
`.debug` — and until this landed the two were the same indigo cookie under the
same name, which makes the pair unusable for the one thing installing both is
for. So `src/debug/` overrides the label and the artwork: `@string/app_name` is
`Entoli (Debug)` there, and three drawables are the same paths with the indigo
turned black.

**The black copies are checked in, not tinted at build time.** A `tint` is one
colour over the whole layer, and the icon is a white cookie with the indigo
showing through it as the field behind and the glyph on top, so tinting flattens
it to a blob. Routing the two colours through a `@color` the debug source set
overrode would have worked; checked-in copies are what the rest of this section
already does, and the cost is the same one — the paths are duplicated, and
editing the artwork means editing both.

Both foregrounds, not only the cookie's, because the icon switcher still works
in a debug build and `ic_icon_background` is shared: draining it and leaving
`ic_prompt_foreground` alone would put indigo details on a black field. The
monochrome layers are shared as they are, being a single colour already — so on
a launcher with themed icons on, the two installs are the same silhouette again
and only the name tells them apart. That is the one case this does not fix.

`appTitle` in `ui/theme.dart` is the Dart half, beside `entoliIndigo` for the
same reason: it is the app's identity written where the platform's copy cannot
be read. It is not a second signal — `MaterialApp.title` *replaces* the launcher
label in Android's recents, so without it a debug build would name itself
"Entoli" there whatever `@string/app_name` said. `_AppBrand` reads it too, so
the bar over an empty pane is not the one place left saying "Entoli"; it is
`Flexible` now because the name is no longer a fixed width and the slot is a
phone's toolbar. It reads `kDebugMode` rather than the platform, so a debug web
build's tab says it as well, which is honest and free. Linux is left alone:
`my_application.cc` hardcodes the window title, `MaterialApp.title` does nothing
on GTK, and there is no second install to tell apart. Profile builds have no
`res/` of their own and so carry the release name and artwork.

## Waking for a trigger

A trigger set while the app was closed fires through AlarmManager, and the
process may have been dead since it was set. Schedules and timers ride this;
a file trigger has nothing here to hand to — it fires while the process runs,
which is what a watcher is. `ReminderReceiver` is the entry
point: it stashes the reminder id in `RemindersChannel`'s held-pending list
(the same shape `AssistantChannel` has for the assistant gesture), starts
`AgentService` synchronously inside the alarm's temporary allowlist window, and
calls `AppEngine.runIfIdle` to cold-start the Flutter isolate if nothing was
running.

**The service starts in Kotlin, not Dart.** `TurnKeepAlive`'s
`BackgroundWork.running(1)` goes through a MethodChannel round trip that may
fall outside the allowlist window; starting `AgentService` directly in the
receiver is what lets the turn run at all. A refusal is caught — an uncaught one
in a broadcast receiver is a crash — and the turn then runs merely killable,
which is where every other platform already is.

**What the receiver started counts as a hold.** `ForegroundWork.holdForAlarm`
is that bookkeeping, and `busy` reads it with the rest: without it the statics
say the process is idle while a reminder is being woken for, and the first
`hold(false)` from anything else — a download finishing, a prefill clearing —
takes `AppEngine.releaseIfUnwanted` at its word and destroys the engine under a
turn that has not registered itself yet. Dart releases it through `doneFiring`
once the scheduler has dealt with the fires, which is also what stops a wake
with nothing to run from holding the process open for good.

**A turn nobody can hold is not started.** The scheduler's own timer fires on
time whether or not anyone is looking, and a backgrounded app may not start a
foreground service at all — so off screen that timer was starting turns nothing
kept alive, and the system killed the process partway through the reply. It now
asks `canHoldTurn` first (`ForegroundWork.busy`, or this process being in the
foreground) and, where the answer is no, hands the fire back to AlarmManager for
the time it was already due. The broadcast comes back within seconds, the
receiver takes the hold inside its window, and the same fire runs held. Once per
reminder: a second refusal means the broadcast is not getting a hold either — a
device with exact alarms denied — and by then running it killable beats not
running it.

**`AppEngine` is the one place the engine is built.** Every way the process
comes to be running Dart goes through `AppEngine.ensure` — an activity launch,
or an alarm waking nothing — so channels and `GeneratedPluginRegistrant` are
registered exactly once and both paths get an identical engine.
`MainActivity.provideFlutterEngine` delegates to it; `configureFlutterEngine`
is a no-op because plugin registration moved into `ensure`, where the default
would otherwise register them a second time. `runIfIdle` executes the Dart
entrypoint headlessly (runApp builds the widget tree with no surface; frames
begin when an activity eventually attaches), guarded by `isExecutingDart` so
`main` never runs twice.

**A cold-started engine is released when its work drains.** `AppEngine.everAttached`
tracks whether an activity ever came up; `ForegroundWork.hold`, when the last
piece of work ends and `!everAttached && !busy`, calls `AppEngine.releaseIfUnwanted`
to destroy the cached engine. Without this, a sticky isolate nobody opened is a
restart that never comes — `main` would not re-run, so a settings file or prompt
edited behind its back would go on being ignored. An engine an activity did
attach to belongs to `MainActivity.onDestroy`'s rules instead.

**The boot receiver re-arms from `reminders.json`**, reading `nextFireAt` (the
epoch millis Dart precomputed) rather than doing recurrence math of its own —
a second copy of that math in Kotlin would drift across DST and month ends.
`TIME_SET` and `TIMEZONE_CHANGED` trigger the same resync. The file is read
through `PathUtils.getDataDirectory` + `"agent-chat"`, the same path
`WorkspaceProvider` uses with no engine running.

**`POST_NOTIFICATIONS` cannot be requested from a receiver**, which is why the
Reminders settings page asks for it when the first reminder is scheduled — an
activity is present there. A device where the app was never opened post-install
gets no notifications from a cold-started reminder; the service still runs, the
turn still completes, and the chat is on disk for the next open.

**The completion notification's tap deep-links to the chat.** `RemindersChannel`
builds an explicit `Intent` to `MainActivity` carrying the chat id (using the
runtime `packageName`, not the namespace — the debug-suffix lesson from
`IconChannel`); `MainActivity.onCreate` and `onNewIntent` hand it to
`RemindersChannel.receive`, which stashes it held-pending and nudges Dart.
`IncomingReminderOpen` (`lib/ui/reminders/incoming_open.dart`) drains it on the
first frame and on each nudge, validates the chat still exists (a temporary
reminder chat can have been swept), and calls `openChat`.

**A turn failure posts on the same port, its own channel.** `RemindersChannel`
posts whatever its `channel` argument names — `reminders` for the reminder
completions, `turns` for a turn that gave up on its retries with nobody
watching (see `lib/ui/chat/CLAUDE.md`, "Automatic retry rounds"). One port and
one tap route, two channels, so silencing one half of the app's bad news is a
channel toggle rather than the feature's off switch.
