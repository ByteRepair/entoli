# Settings, and backing it all up

## Setting overrides

A chat's `meta.json` overrides the app default in `settings.json`. Each level
stores `null` to mean "inherit", shown in the UI as the `Default` option —
always first in its list, with a reset button beside the field.

**A provider is never picked on its own.** Every field here is one list of every
configured model, and the model brings the provider that offers it. There was a
provider field above each of them once, and all it did was narrow the list
below: picking one pinned half a pair, so a level could inherit a model from
above while overriding the provider under it, and the model list had to answer
what to show while the provider still said `Default`. Nothing wanted either.

`Default` is a live reference, not a snapshot: a chat that pins nothing uses
whatever the global default currently is, and retargeting the global retargets
every such chat. `ModelPicker` names what it resolves to under the field.

The title model differs in one thing: nothing inherits from it, so it is a pair
or it is off, and `OptionalModelPicker` leads the same list with `Off` and has
nothing to reset to. The classifier model is the same pattern: a separate
optional pair, used only by auto mode, and off by default.

`settings.json`'s `environment` is what every command runs under, and where a
provider that names its key rather than holding it looks. It is read off disk
when used rather than captured at startup, so an edit applies to the next
command. Settings wins over the process's own environment, but a key already
exported is found without having to be pasted in. Old files with the former
`opencodeEnv` key still load, and rewrite themselves under the new name on the
next save.

The settings page is ten categories, picked from a panel beside it or, below
`navBreakpoint`, from a page of their own. **General** is the app itself:
**Appearance** — the theme, the two colours the palette is seeded from, how
round a corner is, and the app icon, which are what the app looks like; where
the system has a palette of its own a Material 3 Expressive switch takes the
place of the colours, and what any of it reaches is "What the settings page can
change about it" — the **Agent** — command approval mode and the classifier
model, which travel together because auto mode is unusable without one — the
environment, and deleting every chat. **Terminal** is where commands run —
Android itself, or a Linux downloaded from the catalog under it; a category of
its own for the reason Voice is one, and drawn on every platform, where it says
that installing one is Android's. **On-device** is the model that answers
without a network — the pick, what it runs on, and the catalog it is downloaded
from; beside Terminal rather than under LLMs, since it is a machine question
rather than a question about models, and a model loaded there appears under LLMs
like any other. **Voice** is what listens and what speaks, over the catalog they
are downloaded from — its own category rather than a section under General
because the two pickers are two lines and the catalog under them is the rest of
the page. Under the pickers are two fields that never appear together, because
each belongs to a kind of engine: which voice, for a downloaded model, and which
language, for the device's own — see "Which language it is asked in". Where
Android's assistant gesture lands is a section under the same category rather
than a category of its own: what the gesture opens is voice mode, so it is the
same feature approached from the other end, and its two questions were a
category with two lines in it. It keeps a file of its own all the same, since
every other file here is one subject; see "Being the assistant". **Reminders**
is Android's only — a reminder runs a prompt in a new chat at a time you pick,
even when the app is closed — and where the port is unavailable the page says so
and offers nothing,
the way a row for a missing device would. The permission rows re-read on the way
back to the app, since their answers can only change while it is behind in the
system settings the rows open. The editor page is a route of its own;
see "The reminder editor" below, and "Waking for a reminder" in
`android/CLAUDE.md`. **Sync** is paired devices — this device's identity and
name, the relay and TURN settings for internet pairing, the paired-device list,
and the pairing window. See `lib/data/sync/CLAUDE.md` for the threat model and
handshake. **Providers** is the endpoints.
**LLMs** is what a new chat is answered by and what names it. **Memory** is
what one conversation leaves the others: the two `AGENTS.md` files the turn
is read from — the user's own at the root of the data directory and the
project's in its workspace, the latter's imports expanded and a nested one
found on a read joining the turn — with the patterns that keep one of them
out, and the memories the app writes for itself, which the recall, extraction
and tools sub-gates and the Memory LLM beside them steer; the profile pages
edit the files — the global page the user's own, the project page the
project's — and the memories themselves are looked at on a page the settings
draw. The two halves are "Memory" in `lib/data/builtin/CLAUDE.md`. **Data** is all of it at once, out as
one file and back — see "Backing it all up". **About** is the
app rather than anything it does, which is why it is last — see "What the app
is".

## The reminder editor

Four questions and the prompt, in `reminders.dart`. The name is one row and the
date and time the next, sharing it half and half: what a reminder is set for is
both of them, and either alone is half an answer — while a name beside them made
the row three controls where two of them are one.

**The prompt is not typed here.** The middle of the page is what the reminder
will send, rendered the way the chat will render it, over the button that opens
`ReminderPromptPage` — a box that is the whole page, Save and Discard, and
nothing else. A reminder is written once and read many times afterwards, so the
page it is read on shows the message; and a prompt long enough to need the room
had a box a few lines tall to grow in before. Discarding asks, and so does the
back key through a `PopScope`, since it is the one way out that loses what was
typed.

What is typed in it is `CompletionField` — the composer's, so `/commands` and
`@agents` complete there and the `+` offers them; a reminder's prompt is
dispatched through the same library, and being offered them in a chat and not
here was the tell. The preview is `MarkdownBody` under `replyStyleSheet`, which
is the reply's own sheet rather than a second answer to how markdown is set.

**Temporary chat is `TempChatTtlField`**, the chat settings page's combobox and
nothing new: the reminder's chat is a chat, and its TTL is written onto
`meta.json` as it is. It was a switch over a bool, which could name only one of
the five windows the field offers — see "Reminders" in `lib/domain/CLAUDE.md`
for what the old key reads as.

## What the app is

About is four tiles: the icon the app is wearing beside its name and version,
who made it, a link to the repository, and the libraries. Private in
`settings_page.dart` like every other category with no state — the files beside
it are the ones with logic.

The version is read out of the bundle rather than written into Dart, so
pubspec's number stays the only one. `platform.appVersion` is where that lands,
since a web build puts `version.json` beside `index.html` rather than in the
assets — reading the file is the platform's half, and composing the string is
shared. It is awaited into the container in `main` beside the ABI, so nothing in
the UI waits on a future for a string; where it could not be read the line is
simply not drawn, since a version nothing depends on is not worth failing a
startup over.

The build number is the `+42` after it, and it comes from the build rather than
from pubspec — which deliberately carries none, since the Android version code
is derived from the three numbers and a second one to bump is a second one to
forget. So CI passes `--build-number` to every build it makes, the APKs and the
AppImage alike, and a build made by hand says only which version it is.

`package_info_plus` answers the same question and was the first version of this.
It drags `win32` into the build graph of every platform, forks `stat` on Linux
for an install time nothing shows, and refetches on the web with a cache buster
— for one field of a file this reads directly.

The libraries are Flutter's own `showLicensePage`, not a list kept here. The
registry already holds every package that ships, and this app adds the bundled
font and voice licences to it — see "How a reply is set" and "What listens and
what speaks", both of which were written against a licence page that did not
exist yet.

**Narrow, the categories are the page rather than its drawer**, and each one is
pushed over the list. That is the one place this and the chat page differ about
what a panel becomes, and the difference is what is underneath: the sidebar
opens over a conversation, which is what the user came for, while a drawer here
opened over General with the other two categories behind a hamburger — the
structure of the page, reachable only by knowing it was there. As a page it is
the first thing settings shows. Two levels also means leaving a category is the
back gesture, so nothing takes the bar's leading slot and the `Close settings`
action that stood in for the back arrow goes with the drawer.

`_sectionsOf` is what both layouts draw, so a category is the same list of
sections whether it is beside the panel or on a `_CategoryPage`. The page keeps
`_category` in either layout, and a `_CategoryPage` pops itself once the window
is wide: widening puts the category the user was reading beside the panel rather
than under a full-screen copy of itself.

## Backing it all up

The Data category is two buttons: Export writes the whole data directory as one
zip, Import replaces the whole data directory with one and starts the app again
on what was restored. `domain/backup.dart` is the format, `BackupHandoff` is how
the file leaves and arrives, and `AppRestart` is what makes a restore land.

**The members are the files.** Each one is at the path it has under the data
directory, in its own bytes, so a backup opens in any file manager and a
conversation reads as itself. The layout is the format: a directory that grows a
new kind of file is backed up without `backup.dart` being told about it, which
is the same bargain `conv.jsonl` makes.

That bargain is also why the voice models are not in the data directory: three
hundred megabytes of bytes that can be fetched again would be in every export,
and a restore would drag them between machines and delete whatever was already
downloaded. Keeping them outside is what makes both false, rather than an
exception in here that someone has to remember — see "Where the models live".

It was one JSON document holding every file first, and that is worse on every
count that matters. Text in JSON is escaped inside a string inside an array,
binary costs a third more as base64, and nothing compresses, where deflate takes
`conv.jsonl` to a fraction of itself. The one thing JSON was better at, saying
what the document is before anything is deleted for it, a member gives back.

Neither format streams its export: `writeBackup` builds the whole archive and
encodes it in memory, so an export is still bounded by what the device can hold
— `autoClose` frees each member as it is compressed, which is as much of that as
can be given back without `archive_io`, which a browser cannot have. The restore
side does stream, a member at a time. If a workspace ever makes that bound bite,
the fix is encoding into an `OutputFileStream` off web and `BackupHandoff.save`
taking a path rather than bytes.

That member is `backup-meta.json`, holding the format name, the version and when
the backup was made — meta about the backup rather than a file of the data
directory, which is what the name says. ZIP's own comment field would have
carried it, and `archive` writes one, but reading it back means reaching into
`ZipDecoder.directory` and it is decoded as latin-1; a member is read through
the same API as everything else and is there for whoever opens the file. A data
directory holding a file of that name would have it shadowed, and nothing
creates one.

**A restore replaces.** A merge would leave a chat deleted before the backup was
made alive again beside one written after it, which is not what "restore" means.
So the parse comes first and refuses everything it can — not a zip, no manifest,
another format, a newer version — before `restoreBackup` has deleted anything.
The write itself is `writeIncoming`, which is where a path from outside is made
safe to join onto a directory, and an archive member is an `IncomingFile` for
real: bytes not read yet, read once, consumed by the write. That is what
`IncomingFile` being abstract rather than sealed was for.

**The restore runs with no session over the files**, which is why it rides
inside the restart as `whileStopped` rather than happening before it. Everything
that writes to the data directory belongs to the session — a turn, the
half-hourly sweep that *deletes chats*, a checkpoint on its one-second timer —
so stopping the session is the only thing that covers all of them, where a check
against `runningTurns` covers one and goes stale the moment it is read. The
running-turn refusal is still there, but as a courtesy: killing someone's turn
without saying so is the rude way to do the same thing.

**Then the app is built again, and that is the whole of the other half.** The
app is full of things read out of the data directory exactly once — settings
served from memory by `Documents`, the `PromptLibrary`, a live session per chat,
the store's idea of which project each chat is in. Telling each of those to look
afresh was the first version, and it is a
list that has to grow every time something new is read at startup and is
silently wrong when it does not: the reload the user notices missing is the one
nobody remembered to add. So `AppRestart` rebuilds instead, and everything that
was reading the old files is thrown away with the container that held them. It
is also what let `ChatRepository.importBackup` go — its body was that same list,
written out by hand and already two entries long.

Nothing in Flutter re-runs `main` — hot restart is the VM's, and only where
there is a VM service to ask — so `AppSession` is `main`'s work made into a
thing that can be done twice, and `AppRoot` is the widget that does it. With
work to do in between it goes down to nothing first and shows a spinner; with
none it keeps the old session on screen until the next is ready and drops it in
a post-frame callback, since disposing a container the widgets reading it are
still mounted against is disposing it under them. Either way the scope is keyed
on the session, so nothing below is reused. `AppRelaunch` is the mutable relay
in between, because the first session is built before there is a root to ask —
`main`'s doing rather than an accident, since a root that booted itself would
hand the platform's splash a blank frame to cover. Unwired it does nothing at
all, `whileStopped` included, so the failure mode is a restore that never starts
rather than one with nobody left to finish it.

What a restart costs is worth knowing: every `LlmClient`, every session and the
prompt library are built again, and the sidebar reopens with nothing selected.
That is the price of not maintaining the list, and it is paid once, by someone
who has just asked for their data to be replaced.

`BackupHandoff` is a port of its own rather than two more members on
`FileHandoff`: that one is the workspace explorer's, and its per-platform
capability flags are what the explorer's toolbar draws itself from — a backup
asks none of those questions, because every platform has somewhere to put a file
and a chooser to get one back. `FileSelectorBackup` is the whole of it on the
desktops and the web, `getSaveLocation` being a dialog on one and a download on
the other. Android is the exception and `SharedBackup` is why: `file_selector`
implements no save dialog there, so a backup leaves through the share sheet,
which is `FileHandoff`'s. An intent carries a file rather than bytes, so the zip
is written to the cache and `FileHandoff` then stages a copy of its own under
the one path a `FileProvider` will mint URIs from — the archive is written
twice, which is what reusing that route out costs rather than opening a second
one.
