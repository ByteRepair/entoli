# The Android half

## Staying alive off screen

Android kills a process nobody is looking at, and a turn is minutes of a model's
time and a half-written reply. `AgentService` is a `dataSync` foreground service
that says the process is busy; `TurnKeepAlive` starts and stops it from
`AgentBackend.runningTurns`, which is the chats `BuiltinBackend` has an agent
running for. It is a `ValueListenable` of ids rather than a count so that Stop
can abort each one, which is also why there is no `abortAll` — one way to stop a
turn.

**Three services, not one.** `VoiceService` holds the microphone while voice
mode is listening and `DownloadService` holds a model being fetched, and both
are as much work the process must not be killed in the middle of as a turn is.
They are separate because a service has one foreground notification and these
are three different things to stop — and because from Android 14 the one that
holds the microphone has to say so, hold `RECORD_AUDIO`, and be started while
the app is in use, none of which a `dataSync` service may claim. Everything
about *how* a service is held, stopped, refused and woken is `ForegroundWork`;
each of the three says only which it is and what its notification reads.
`BackgroundWork` therefore carries a kind rather than a count, and
`stopRequests` says which button was pressed — killing every turn because a
download was cancelled is not what the user pressed. The wording stays in Kotlin
for the first two; a download's cannot, since which model is being fetched is
the catalog's and Kotlin has never heard of the catalog.

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
change.

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
it is a directory like any other.

A data directory still in the layout that came before this one reads as empty.
Migrating it is `AppConfig.migrate`'s, and it happens the next time the app is
launched; doing it from here would be a second copy of that with no engine
running to check the result.

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
editing one means editing all of them — there is no generator.

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
