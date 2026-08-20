# Settings, and backing it all up

## Setting overrides

A chat's `meta.json` overrides the app default in `settings.json`. Each level
stores `null` to mean "inherit", shown in the UI as the `Default` option —
always first in its list, with a reset button beside the field. Pinning a model
pins its provider too: the registry keys clients by provider id, so the two are
only ever sent as a matched pair.

`Default` is a live reference, not a snapshot: a chat that pins nothing uses
whatever the global default currently is, and retargeting the global retargets
every such chat. With nothing to inherit, the model list stays empty rather than
falling back to a provider — a guessed default would mean something that shifts
as providers come and go.

Both settings pages render the same `ProviderModelSelector`; it owns those
rules, and each page only says where the values come from and where they go.

The title model is the exception: nothing inherits from it, so it is a pair or
it is off, and `OptionalModelPicker` offers every configured model in one list
with `Off` at the top rather than a provider field and a model field. The
classifier model is the same pattern: a separate optional pair, used only by
auto mode, and off by default.

`settings.json`'s `environment` is what every command runs under, and where a
provider that names its key rather than holding it looks. It is read off disk
when used rather than captured at startup, so an edit applies to the next
command. Settings wins over the process's own environment, but a key already
exported is found without having to be pasted in. Old files with the former
`opencodeEnv` key still load, and rewrite themselves under the new name on the
next save.

The settings page is eight categories, picked from a panel beside it or, below
`navBreakpoint`, from a page of their own. **General** is the app itself: the
default project's workspace (which has nowhere else to be reached from),
**Appearance** — the theme and the app icon, which are the two things the app
looks like — the **Agent** — command approval mode and the classifier model,
which travel together because auto mode is unusable without one — the
environment, and deleting every chat. **Terminal** is where commands run —
Android itself, or a Linux downloaded from the catalog under it; a category of
its own for the reason Voice is one, and drawn on every platform, where it says
that installing one is Android's. **On-device** is the model that answers
without a network — the pick, what it runs on, and the catalog it is downloaded
from; beside Terminal rather than under LLMs, since it is a machine question
rather than a question about models, and a model loaded there appears under LLMs
like any other. **Voice** is what listens and what speaks,
over the catalog they are downloaded from — its own category rather than a
section under General because the two pickers are two lines and the catalog
under them is the rest of the page. **Assistant** is where Android's assistant
gesture lands — see "Being the assistant". **Providers** is the endpoints.
**LLMs** is what a new chat is answered by and what names it. **Data** is all of
it at once, out as one file and back — see "Backing it all up".

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
the store's idea of which project each chat is in, the draft the repository
holds. Telling each of those to look afresh was the first version, and it is a
list that has to grow every time something new is read at startup and is
silently wrong when it does not: the reload the user notices missing is the one
nobody remembered to add. So `AppRestart` rebuilds instead, and everything that
was reading the old files is thrown away with the container that held them. It
is also what let `ChatRepository.importBackup` go — its body was
`deleteAllChats` and a dropped draft, which is that list with two entries.

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
