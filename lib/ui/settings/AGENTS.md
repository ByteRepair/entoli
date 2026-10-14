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
or it is off, and its `ModelPicker` leads the same list with `Off` and has
nothing to reset to. The classifier model is the same pattern: a separate
optional pair, used only by auto mode, and off by default.

`settings.json`'s `environment` is what every command runs under, and where a
provider that names its key rather than holding it looks. It is read off disk
when used rather than captured at startup, so an edit applies to the next
command — and reaches a persistent shell by respawning it, since a command
already running keeps what it started with. Settings wins over the process's
own environment, but a key already exported is found without having to be
pasted in. A project carries the same list of its own in `project.json`,
edited from its settings page, and a name set there wins over one set in
`settings.json`. Old files with the former `opencodeEnv` key still load, and
rewrite themselves under the new name on the next save.

The settings page is fifteen categories, picked from a panel beside it or, below
`navBreakpoint`, from a page of their own. The order is the `SettingsCategory`
enum's, which is also where the groupings live: a `dividerAbove` on the enum
says a group ends before that category, and the list draws a `Divider` ahead of
the tile — one source of truth for both. The six drawn groups: **General,
Providers, On-device, LLMs** (the app and the plumbing that answers a chat);
**Memory, Voice, Triggers** (what a conversation does beyond the text);
**Agents, Skills** (what a message addresses by name); **Terminal, Byte
Repair** (where commands run); **Sync, Data** (the device and all of it at
once); and **Welcome, About** (the app rather than anything it does), last.
**Welcome** is the
tour rather than a list of sections — `welcome_page.dart`, not this file — so
`_categoryBody` renders it whole where every other category is
`ListView(children: _sectionsOf(...))`; its switch arm here is exhaustiveness
only. It is the first-run screen too: a `WelcomeGate` wrapper in the home chain
(around the shell, under the `Incoming*` wrappers, so what they open stays above
the tour) shows `WelcomePage` instead of the shell while `welcomeSeen` in
`settings.json` is still false, and the tour's Done writes the flag through the
notifier, which swaps the shell in. The tour is the home content, not a route
over it, so the back key cannot skip it and there is no back arrow; the tour
also runs embedded here and has nothing of its own to leave. Its second and
third pages embed
`DefaultsSection`, `InstructionsSection` and `AutoMemorySection`, which live in
`llm_settings.dart` and `memory_settings.dart` because two hosts share them —
the same one-subject-per-file rule the other categories follow. A row added to
one is on the tour the moment it is here. **General** is the app itself:
**Appearance** — the theme, the two colours the palette is seeded from, how
round a corner is, and the app icon, which are what the app looks like; where
the system has a palette of its own a Material 3 Expressive switch takes the
place of the colours, and what any of it reaches is "What the settings page can
change about it" — the **Agent** — command approval mode and the classifier
model, which travel together because auto mode is unusable without one — the
standing permission rules the agent consults before any of it, the environment,
and deleting every chat. **Update** is the app keeping itself current: one
switch, shown exactly where the platform half exists — Linux, Windows, macOS —
and absent everywhere else without a word, since a phone and the web reach
their newest build by means the row would only stand in front of. What the
check then does is the platform side's (see "The automatic update" in the root
notes), so the row's own story is one line: newer release, downloaded and put
in place of this build. **Terminal** is where commands run —
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
every other file here is one subject; see "Being the assistant". **Triggers**
is drawn where the port is available — Android fires a schedule with the app
closed, macOS wakes it through launchd (both answer `schedules` yes; see
"Waking for a trigger" in `macos/AGENTS.md`), iOS delivers the moment a
notification whose turn runs at the next open (`schedules` yes too; see
"Triggers" in `ios/AGENTS.md`), Linux notifies what a trigger
did but cannot wake the process, and the page's description says which
(`ReminderAlarms.schedules` is the question) — and where the port is
unavailable it says so and offers nothing, the way a row
for a missing device would. The permission rows re-read on the way
back to the app, since their answers can only change while it is behind in the
system settings the rows open. The editor page is a route of its own;
see "The trigger editor" below, and "Waking for a reminder" in
`android/AGENTS.md`. **Skills** is the list of what the agent can be told to do by name — the bundled ones, which ship with the app, and the user's own, imported from a `.skill` file or removed with their files. The user's skills live in their own directory beside the extracted presets, so a bundled one is not deletable and a user's is; import and delete are the two things that change it, and they reload the library the moment they are done, the one way a change to it lands without a restart, where a skill dropped into the directory by hand still waits for one. **Every row opens the skill view page** (`lib/ui/skills/skill_view.dart`) — the description, the SKILL.md body rendered the way a reply is, the files, and the conformance problems where there are any, since the loader skips a skill that does not conform to the Agent Skills spec and this page is where the skip says why. The page's scan validates every folder in the project's own directory, so a skipped skill is a row of its own (`Not loaded`, warning badge, removable) rather than an absence with only a log line behind it, and a loaded row with a badged folder carries a warning icon ahead of its Export. **Export rides every row** — bundled and inherited included, since what the library serves is what the user is reading — through `prompt_export.dart`, which resolves the bytes the way the library does (the page's own directory, then a bundled preset, then the default project's) and zips a skill under its own folder, because that folder is what a `.skill` import names a skill by. The file leaves through `BackupHandoff`, the ungated port the backup rides, so a save dialog on the desktops, a download on the web and the share sheet on Android are all the same call. The import flow and the install-to combobox are the **footer**, fixed to the bottom of the page so they do not scroll with the list — the section owns its own scroll, and the hosts (`_categoryBody`'s second special case beside Welcome, the project settings page's prompts page) render it directly rather than under a `ListView` of their own. The same widget is a project settings page's too, under a `project` parameter: it then reads that project's library and scans that project's directory, so an entry it holds is editable there and everything else is a row that says where it came from — `Inherited` from the default project, or `Bundled`. A built-in's page is the read-only version of the same thing: no import, no remove, the badges and the export only, since what a turn in it may have is the spec's to say. A user project's page imports without the destination combobox — it is in that project — and the global page's import carries one, `Global` default, where a skill the user picks can land in any project. The skill-install preview page has the same combobox, so a model-drafted skill is aimed the same way; `InstallDestination` is the one widget both carry. A project's agents page is the same widget with `@name` prose: add, edit and delete against the project's directory, inherited rows badged. See "Skills and agents" in `lib/domain/AGENTS.md`.
**Agents** is the list of what a message can address by name — the bundled ones, which ship with the app and are read-only, and the user's own, written in-app and editable or removable. An agent is one flat `.md` file (a system prompt with `description` frontmatter), so it is written through an editor page rather than imported the way a skill's directory is; the name is the file name, and editing it on an existing agent renames the file — the new `.md` is written before the old one is taken away, a rename onto a name another agent holds is refused in the editor, and the only thing a rename loses is a new mention of the old name, since a mention already written into a conversation keeps the meaning it was recorded with. **Import agent** is the one way an outside `.md` comes in: it lands under its file's own name, with a replace-confirm where the name is taken and a refusal for an empty body, rather than through the editor — an editor pass before the write would be a second way to make the name and the file name diverge. Add and Import agent are the fixed footer, the two-button row the backup section draws. Export rides every row, the same `BackupHandoff` route the skills page takes, the `.md` itself the file — the picture is the device's own convenience and stays. Every row leads with the agent's profile picture (`AgentPicture`) — a person mark until one is set, resolved over the library's tier walk by `agentPictureProvider` — which the editor takes as its picker face too: a tap opens the chooser (PNG only, a non-PNG pick refused with a line saying so), picked bytes live in the editor until Save, and a remove beside the circle takes them off; a save touching neither leaves what the agent already had. The picture is `<name>.png` beside the `.md`, written, replaced, moved on a rename and deleted by the same `withWritableDir` block the `.md` rides, and deleted with the agent — every write here invalidates the provider the rows read. Add, edit, delete and import reload the library the moment they are done, the same one way a change to it lands without a restart — every project's where the page is the global one (the default directory is a rung of every project's tier walk, so an inherited agent and an inherited picture go stale everywhere if only `promptLibraryProvider(null)` is rebuilt; skills keep the same branch), the project's own where it is a project's page. See "Skills and agents" in `lib/domain/AGENTS.md`.
**Byte Repair** is the tooling for the built-in project of the same name: a
banner saying whether the configured terminal env can run it, a button that
runs a bundled install script through that env to create the project's own
rootfs instance and put `make`, `github-cli` and ESBMC into it, a button to
import a local ESBMC binary into the rootfs, a button to delete the whole
environment (rootfs, workspace, and all chats in the project), and the
versions found afterwards. "Run Setup" owns the full lifecycle — it copies
the base rootfs from cache, runs the install script, and writes a
`.setup-complete` marker — so the turn path no longer creates the rootfs
lazily. The chat page gates the composer on that marker, showing a "setup
required" bar until it is there; on the host the marker is not enough either,
since the fetched tools live in a cache directory that can be emptied between
setups, so the binary is asked after too. Where the tools land follows the env:
inside a rootfs they go to the guest's own `/usr/local/bin`; on Linux they go
to `<cacheDir>/byte-repair/bin`, which the project's turns are given on PATH —
so Byte Repair works on the host env with no root and nothing installed into
the machine, and a tool already on the machine is used rather than fetched.
See "Byte Repair's environment, in three variables" in `lib/data/local/AGENTS.md`.
On
Android the "Host" terminal env has no package manager, so the category says
so and hides the rest until a rootfs is picked from Terminal; the desktops'
host shells are each given an install destination and so are capable, the
banner over the buttons being drawn where there is none — iOS and the web.
The delete sits below the banner everywhere the
category is drawn, since the workspace and the chats are data wherever the
tooling is not: its confirm message's environment clause is worded by the
store's `environmentDeletion`, asked off the disk rather than assumed off
the platform, so a delete over a project whose setup left nothing behind
names the workspace and the chats alone. **Sync** is paired devices — this device's name,
the paired-device list, and the
pairing controls. A pairing never renders inline: window, invite and pasted
code all move to a screen of their own that ends on a paired screen naming
the device, with Pair another device on it — see "The pairing flows as pages"
in `lib/data/sync/AGENTS.md`. A paired device's row clicks through to its own
page (Paired device page, `lib/ui/settings/paired_device_page.dart`) — the
record and a rename, then both fingerprints under "Device fingerprint" and
"This device" with the explanation of the comparison they exist for. The Sync
list itself draws no fingerprint. The relay and TURN settings are screens
of their own behind two rows on the page, and Keep connected off screen is
Android's row only — the one platform whose process freezes with the screen.
See `lib/data/sync/AGENTS.md` for the threat model and
handshake. **Providers** is the endpoints — and the keys, which are not in
`settings.json` at all: a key typed into the provider dialog (or the
recommended-provider card) goes to the secret store, under the provider's id,
and the row says "key stored" rather than showing any of it. The dialog's key
field is tri-state — typed text stores, an empty field over a stored key
keeps it, and the explicit remove clears it — because an empty field alone
cannot say keep from clear once the field no longer echoes what is stored.
The TURN password is in the store the same way; the TURN username is not a
secret and rides in `settings.json` beside the URL.
**LLMs** is what a new chat is answered by and what names it, under a
**Turns** section beside it — how a turn runs and is bounded: the retry
rounds, the step limit, the Total Context window and the Auto-compact switch
and share. **Memory** is
what one conversation leaves the others: the two `AGENTS.md` files every turn
is read from — the user's own at the root of the data directory and the
project's in its workspace — and the ways a turn may keep what they pull in
out: imports and the nested ones found on a read, both on by default, and the
patterns that keep a file out; the built-in projects read a note the app ships
instead of any file. Beside them the memories the app writes for itself, which
the recall, extraction and tools sub-gates and the Memory LLM steer; the
profile pages edit the files — the global page the user's own, the project
page the project's, and no built-in project's — and the memories themselves
are looked at on a page the settings draw. The two halves are "Memory" in
`lib/data/builtin/AGENTS.md`. **Data** is all of it at once, out as
one file and back — see "Backing it all up". **About** is the
app rather than anything it does, which is why it is last — see "What the app
is".

## The trigger editor

The name, the prompt, and one row of "When" — a `SegmentedButton` over the
three sources, each kind bringing its own rows under it: a schedule its date
and time and repeat, a timer its countdown minutes, a file watch its paths,
its kinds of change and its cooldown. Beside them the "Address to" row: the
member the fire names, from the trigger's project's library, or nothing for
the whole room — one row for both targets, since addressing is not a
property of where the fire lands. A stored member the library has since
lost keeps its place in the list marked `(deleted)` with the line saying a
fire will reach the whole room, and is kept or exchanged rather than
silently cleared. The kinds' rows are switched on the
segment, so switching kinds does not carry one's data into another's; a
`trigger_set` the agent registered shows as its own page instead: the prompt
read-only and the project/TTL rows gone, the switch and the delete the whole
of what is editable, since the prompt is its conversation's and an edit would
be a conversation rewrite from a settings page.

**The prompt is not typed here.** The middle of the page is what the trigger
will send, rendered the way the chat will render it, over the button that opens
`TriggerPromptPage` — a box that is the whole page, Save and Discard, and
nothing else. A trigger is written once and read many times afterwards, so the
page it is read on shows the message; and a prompt long enough to need the room
had a box a few lines tall to grow in before. Discarding asks, and so does the
back key through a `PopScope`, since it is the one way out that loses what was
typed.

What is typed in it is `CompletionField` — the composer's, so `/skills` and
`@agents` complete there and the `+` offers them; a trigger's prompt is
dispatched through the same library, and being offered them in a chat and not
here was the tell. The preview is `MarkdownBody` under `replyStyleSheet`, which
is the reply's own sheet rather than a second answer to how markdown is set.

**Temporary chat is `TempChatTtlField`**, the chat settings page's combobox and
nothing new: the new chat a trigger makes is a chat, and its TTL is written
onto `meta.json` as it is. It was a switch over a bool, which could name only
one of the five windows the field offers — see "Triggers" in
`lib/domain/AGENTS.md` for what the old key reads as.

## What the app is

About is four tiles: the icon the app is wearing beside its name and version,
who made it, a link to the repository, and the libraries. Private in
`settings_page.dart` like every other category with no state — the files beside
it are the ones with logic.

The version is read out of the bundle rather than written into Dart, so
pubspec's number stays the only one. `tool/prepare.sh` writes `version.json`
from pubspec's `version:` and it is declared as an asset, so every platform's
bundle carries it; Flutter writes its own `version.json` for Linux and Web,
which overrides ours where one exists, and on every other platform ours is the
only copy. `platform.appVersion` reads it, since where it lands varies — the
assets on one, a file beside `index.html` on the other — and composing the
string is shared. It is awaited into the container in `main` beside the ABI,
so nothing in the UI waits on a future for a string; where it could not be
read the line is simply not drawn, since a version nothing depends on is not
worth failing a startup over.

The build number is not reported. It comes from the build rather than from
pubspec — which deliberately carries none, since the Android version code is
derived from the three numbers and a second one to bump is a second one to
forget. CI passes `--build-number` to every build it makes, the APKs and the
AppImage alike, and it stays in the version code and the attestation rather
than on the About page.

`package_info_plus` answers the same question and was the first version of this.
It drags `win32` into the build graph of every platform, forks `stat` on Linux
for an install time nothing shows, and refetches on the web with a cache buster
— for one field of a file this reads directly.

The libraries are Flutter's own `showLicensePage`, not a list kept here. The
registry already holds every package that ships, and the app adds the bundled
font and voice licences to it — see "How a reply is set" and "What listens and
what speaks", both of which were written against a licence page that did not
exist yet. The bundled skills join them one entry per skill that carries its
own `LICENSE.txt`, named after the skill and read from the embedded data —
`registerBundledSkillLicences` — so the notice travels with the skill wherever
the skill is redistributed, which is what the fetched ones' Apache licence
asks.

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

It is also why the provider API keys and the TURN password live in the secret
store rather than in `settings.json`: `sync/` is the one directory a backup
skips, so a secret behind it is out of every export, where a key in a JSON
file the format carries by default would ride in all of them. What a backup
costs the user is stated plainly — restoring onto another device does not
bring the keys, and they are typed again where the store is local to it (the
keyring is a machine's own).

A per-project `rootfs/` is the one re-fetchable tree that *does* live under the
data directory, because a built-in with rootfs isolation keeps its living
filesystem there beside the chats. `writeBackup`'s `skipDir` leaves it out for
the same reason the voice models are outside it, and for a second one: proot's
mode-0000 bind stubs (see `tree_ops.dart`) sit inside it, and `dart:io` cannot
list a mode-0000 directory, so a walker that reached one would throw. The
restore clear routes every top-level directory through `removeTree` rather than
a plain recursive delete, so the stubs a skipped `rootfs/` leaves behind are
cleared on the way in too — the same `removeTree` the rootfs stores use, so the
one function that knows how to delete a stub-bearing tree is the one the
restore reuses.

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
