# Settings, and backing it all up

## How Settings is built

Every settings page is a plain widget. The layers under them:

- **The store** (`packages/entoli_core/lib/model/settings/`). `settings.json`,
  `project.json` and a chat's `meta.json` are each a `SettingsDocument`: the
  JSON as the source of truth, read and written through a `Setting` declaration
  per key in `SettingKeys` — the key, a codec, the levels it may be set at, and
  for the app's level a fallback. A value equal to its fallback is not written
  at the app's level, so a file that predates a default gets it; a key this
  build does not know is kept through a save; a key that once had another name
  was moved by `migrations.dart`, so the reader knows only today's.
  `AppSettings`, `ProjectSettings` and `ChatMeta` are typed views over their
  documents, a getter and a setter a key.
- **Scopes** (`lib/app/settings/scope.dart`). `AppScope`, `ProjectScope` and
  `ChatScope` are the objects that read and write a level: what this level
  holds (`own`), what it would take from above (`inherited`), and `write`. A
  project inherits the app's; what only projects and chats hold — the
  sandbox, the rules — a project other than the default inherits from the
  default project's, the tier every other project builds on. A chat's scope
  is a draft over the page's copy of its `meta.json`, saved whole by Save.
  **Unset is offered where the level inherits — a project, a chat — or where
  the key has no fallback even at the app's** (`SettingsScope.offersUnset`);
  a control then shows the level's own value (`shown`) and stands where the
  level above does, with a reset back to it once this level picks.
- **Scoped widgets** (`scoped.dart`). One setting at one level, drawn as
  the control its value wants: `ScopedSwitch`, `ScopedChoice`,
  `ScopedLevels`, `ScopedCount`, `ScopedModel` and `ScopedEnvironment`. Each
  reads its level through `scopeOf` — `scopeAt` over the widget's ref
  (`WidgetReader`, `packages/entoli_core/lib/transcript/reader.dart`), so it rebuilds
  as the documents change — and writes back through it. What a change sets off
  beyond the key — a restart to say, a re-anchor of every chat's TTL — is a
  `write` handed to the widget, through the notifier setter that does it.
- **Categories** (`settings_category.dart`, `settings_pages.dart`).
  `SettingsCategory` is the list: its order, label, icon, the group a
  `dividerAbove` starts, and `offered`, whether this platform can do
  anything the category sets. `settingsCategoryBody` picks a category's
  widget, one file each (`general_settings.dart`, `llm_settings.dart`, and
  so on).
- **The logic** is in `lib/app/`, so the widgets only draw: the provider
  dialog's `ProviderEdit`, the trigger editor's `TriggerDraft`, the
  permission rules, CLI sign-in, on-device downloads and pairing under
  `lib/app/settings/`; the backup's two directions (`backup_actions.dart`),
  the browser pick (`browser_settings.dart`), Byte Repair's setup
  (`byte_repair.dart`), a model described by hand (`custom_model.dart`,
  drawn by `CustomModelPage`), and the file work behind the Agents and
  Skills pages (`lib/app/prompts/`).

The default and title model pickers are widgets (`newChatModelField`,
`titleModelField` in `llm_settings.dart`), which the welcome tour draws too.

The welcome tour is not settings: it is a widget page (`WelcomePage`,
`welcome_page.dart`), and Settings' Welcome opens it by `welcomeRoute`.

The chat and project settings pages are widgets too:
`ChatSettingsPage` and `NewChatSettingsPage` (`lib/ui/chat/chat_settings_page.dart`)
and `ProjectSettingsPage` (`lib/ui/sidebar/project_settings_page.dart`). Their
rows are the same `scoped.dart` widgets at the page's level, and where a row
is a setting another page draws too — Running commands (`ApproveModeChoice`),
the sandbox (`SandboxSettings`), the permission rules — it is that page's
widget given the level, so the rules and the words are said once. A chat's
level is a `ChatAddress`: its draft's `meta.json` (`ChatSettingsDraft` in
`lib/app/chat_settings_draft.dart`), written as the page changes it and saved
whole by Save. What a project's page does beyond its settings — counting and
deleting it, here or on a paired device, and its work folders — is
`ProjectEdits` (`lib/app/project_edits.dart`). Every row of a level that
inherits carries its reset, and a choice shows where it stands unset — the
thinking slider at the level above's answer. While a paired device is away,
its project's rows are drawn and do nothing.

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
`settings.json`. A file with the former `opencodeEnv` key had it moved under
the new name by 8.4.0's migration.

The settings page is fifteen categories, picked from a panel beside it or, below
`navBreakpoint`, from a page of their own (see "Narrow, the categories are the
page" below). The order is the `SettingsCategory`
enum's, which is also where the groupings live: a `dividerAbove` on the enum
says a group ends before that category, and the list draws a `Divider` ahead of
the tile — one source of truth for both. The six drawn groups: **General,
Providers, On-device, LLMs** (the app and the plumbing that answers a chat);
**Memory, Voice, Triggers** (what a conversation does beyond the text);
**Agents, Skills** (what a message addresses by name); **Terminal, Byte
Repair** (where commands run); **Sync, Data** (the device and all of it at
once); and **Welcome, About** (the app rather than anything it does), last.
**Welcome** is the
tour rather than a list of sections: `WelcomePage`, a `PageView` walked by
swipe or by Back and Next under its dots, each page fading as it leaves,
which the category's button opens. It is the first-run
screen too: `openFirstRun`, asked as the app starts, opens it
over the app while `licenceAccepted` in `settings.json` is still false, and
on a first launch it cannot be left but by its Done, which writes the flag.
Ahead of it, `SetupPage` (`lib/ui/initial_setup_gate.dart`) runs over the
device's `SetupPlan` while a step of it is not done, its sequencing the
`FirstRunSetup` notifier (`firstRunSetupProvider`, `lib/app/first_run.dart`)
and the page only what it draws. A plan is what a platform hands
the one setup screen: its `SetupStep`s in order and a `SetupProgress` — the
bar's policy. `setupPlanProvider` is where each platform submits its plan: where a
Linux can run (proot on Android, the emulator on iOS) Alpine as the terminal,
so a phone user never has to find the Terminal page, its bar the download
alone (`StepProgress`); where the agent's browser is one the app launches —
the desktops — Helium as that browser, which makes the embedded browser the
desktops' default where it used to be off, its bar the whole plan
(`PlanProgress`, each step an equal share and unpacking its `unpackShare` of
that, so it only moves forward). The page runs the steps one after another,
each started when the one before is done or skipped; a step is done when its
setting is picked, so the page has no Next. A failure offers Retry, or a Skip
that lasts the launch. A step subclass says what it is called, the catalog it
downloads through, when it is done, and how it is picked; the line under the
bar is "Downloading" or "Unpacking" and that name. The tour is four
pages, and a page is added only when what it says cannot ride one already
there. The intro says what the app is, a short list under the name rather than
a slide per point. The model page holds Next until some model is reachable and
a default is picked, and picks nothing itself: its rows are the services a
plan someone pays for answers through (`welcomeProviders`), then Local Model
and Advanced. A service is connected as its kind is — a CLI by `connectCli`,
installed if Entoli has no copy of it, which is the one place a program is
installed (no first-run step does it ahead of time), and signed in if it is
not (`showCliSignIn`: a
`CliSignInDialog` over a `CliAccount` of its own, the program's own sign-in
run, the page it prints opened from a link on it, a code the page shows
pasted back) — `connectCli` itself lives in `app/settings/cli_account.dart`
and is handed the sign-in to run, so it is tested with no dialog — an API in the
provider dialog started on its preset (`editProvider`) — and
adopted, answering new
chats, titles and the classifier at its own defaults; connecting one already
configured adopts that entry rather than adding a second. The first
on-device model downloaded fills those roles where nothing answers yet
(`ModelDownloads.landed`), so Local Model needs no picking either.
The provider dialog is the way to sign in outside the tour: a CLI's entry
shows `CliAccountSection`: whether the account in the entry's own folder is signed in,
Sign in where it is not, and Sign in again where it is, which signs the
program out first so the sign-in is a new one, perhaps another account. The
steps are `CliAccount` (`app/settings/cli_account.dart`), which every place
that signs a program in draws through `CliSignInDialog`, which keeps the app
alive while it is open and closes when the program exits.
The default and title model pickers are drawn only where models are
reachable and nothing answers new chats — a setup from before this — which is the one case Next
would otherwise wait on with nothing to press. The extras page is optional throughout: a row into each extra, a row
dropped where its category is not offered. Memory is not among them, its own
page's switch being the one place it is turned on, nor is anything already on
by the time the tour runs: the terminal, which the setup page installs where
one is needed, and the browser — Helium installed by the desktops' setup, the
phones' WebView on by default. The
last page says AI can make mistakes and holds Done behind a checkbox taking
responsibility for what the user lets it do, at the end of the AGPL text
(`bundledLicence`, embedded from `LICENSE` by `tool/gen_licence.dart`), so
reaching it means passing the licence. The tick frees Done; Done is what
stores it, as `licenceAccepted`, the flag both gates read. It replaced
`welcomeSeen`, so an install from before walks the tour once more. Unticking on
a replay confirms, clears it and restarts the app (`AppRestart`), which stops
whatever the session was running and lands on the tour: a restart rather than a
close, since iOS cannot close itself and Apple rejects apps
that try. Done, on
the first run or a replay, opens a "Welcome to Entoli" chat in the default
project and leaves settings for it (`finishWelcomeTour`): its log is seeded with a
`/entoli-welcome-party` message, composed like any `/skill` message so the
skill's instructions ride every later turn without a system record, and the
skill's greeting as a finished assistant turn under it. **General** is the app itself:
**Appearance** — the theme, the two colours the palette is seeded from, how
round a corner is, and the switch that puts the new-chat screen's
command chips on it, which are what the app looks like; where
the system has a palette of its own a Material 3 Expressive switch takes the
place of the colours, and what any of it reaches is "What the settings page can
change about it" — the environment, and deleting every chat. **Update** is the app keeping itself current: one
switch, shown exactly where the platform half exists — Linux, Windows, macOS —
and absent everywhere else without a word, since a phone reaches its newest
build by means the row would only stand in front of. What the
check then does is the platform side's (see "The automatic update" in the root
notes), so the row's own story is one line: newer release, downloaded and put
in place of this build. **Terminal** is where commands run —
Android itself, or a Linux downloaded from the catalog under it; a category of
its own for the reason Voice is one, and drawn on every platform, where it says
that installing one is Android's. Its sections are the **Driver** picker, a
**status card**, and the default project's **Permissions** with the Sandbox
switch under them — moved there from LLMs, beside what they govern. The card
is the one place the sandbox policy is shown: the picker's options name the
environment and nothing more, and the switches elsewhere say only "Sandbox".
It reads two things, the picked driver's `Confinement` and the default
project's switch, and says one of three sentences — no support, supported but
off, enforced. The rules (`PermissionRulesSection`) and the Sandbox switch
with its grants (`SandboxSettings`) take the level they show, so a project's
page draws the same at its own, where each switch inherits the default
project's until set. **On-device** is the model that answers
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
category with two lines in it. Both the pickers and the downloads and that
section are drawn only where the ports say there is something to configure or
to fetch — `Voice.hasModelCatalog` and `AssistantLaunch.hasGesture` — which is
why iOS draws the mode and the language and nothing else. It keeps a file of its own all the same, since
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
`android/AGENTS.md`. **Skills** is the list of what the agent can be told to do
by name — the bundled ones, which ship with the app, and the user's own,
imported from a `.skill` file or removed with their files. The user's skills
live in their own directory beside the extracted presets, so a bundled one is
not deletable and a user's is; import and delete are the two things that change
it, and they reload the library the moment they are done, the one way a change
to it lands without a restart, where a skill dropped into the directory by hand
still waits for one. **Every row opens the skill view page**
(`lib/ui/skills/skill_view.dart`) — the description, the SKILL.md body rendered
the way a reply is, the files, and the conformance problems where there are any,
since the loader skips a skill that does not conform to the Agent Skills spec
and this page is where the skip says why. The page's scan validates every folder
in the project's own directory, each time the page is shown, so a skipped skill
is a row of its own (`Not loaded`, a warning mark, removable) rather than an
absence with only a log line behind it, and a loaded row with a badged folder
carries the warning mark too; what is wrong is the view page's to say. **Export
rides every row** — bundled and inherited included, since what the library
serves is what the user is reading — through `prompt_export.dart`, which
resolves the bytes the way the library does (the page's own directory, then a
bundled preset, then the default project's) and zips a skill under its own
folder, because that folder is what a `.skill` import names a skill by. The file
leaves through `BackupHandoff`, the ungated port the backup rides, so a save
dialog on the desktops and the share sheet on Android are the same call. Beside
Export each row has **Copy install link**, the entry as an `entoli://` link (see
"Links into Entoli" in `lib/ui/AGENTS.md`). The import and the install-to choice
are the footer, pinned under the list so they do not scroll with it. Both pages
are widgets (`skills_settings.dart`, `agents_settings.dart`) taking the level
they show: the app's page is the default project's, and `openProjectPrompts`
(`project_prompts_page.dart`) pushes either at a project's `ProjectAddress`, a
paired device's included, whose entries are shown and not changed. A project's
page reads that project's library and scans that project's directory, so an
entry it holds is editable there and everything else is a row that says where it
came from — `Inherited` from the default project, or `Bundled`. A built-in's
page is the read-only version of the same thing: no import, no remove, the
badges and the export only, since what a turn in it may have is the spec's to
say. A user project's page imports without the destination combobox — it is in
that project — and the global page's import carries one, `Global` default, where
a skill the user picks can land in any project. The skill-install preview page
asks the same, so a model-drafted skill is aimed the same way. A project's
agents page is the same page with `@name` prose: add, edit and delete against
the project's directory, inherited rows badged. See "Skills and agents" in
`packages/entoli_core/lib/model/AGENTS.md`. **Agents** is the list of what a
message can address by name — the bundled ones, which ship with the app and are
read-only, and the user's own, written in-app and editable or removable. An
agent is one flat `.md` file (a system prompt with `description` frontmatter),
so it is written on `AgentEditorPage` rather than imported the way a skill's
directory is; the name is the file name, and editing it on an existing agent
renames the file — the new `.md` is written before the old one is taken away, a
rename onto a name another agent holds is refused in the editor, an add onto one
asks to replace it, an agent with no system prompt is not saved, and the only
thing a rename loses is a new mention of the old name, since a mention already
written into a conversation keeps the meaning it was recorded with. **Import
agent** is the one way an outside `.md` comes in: it lands under its file's own
name, with a replace-confirm where the name is taken and a refusal for an empty
body, rather than through the editor — an editor pass before the write would be
a second way to make the name and the file name diverge. Export and Copy install
link ride every row, the same `BackupHandoff` route the skills page takes, the
`.md` itself the file — the picture is the device's own convenience and stays.
Every row leads with the agent's face (`AgentPicture`) — a person mark until one
is set, a still where it is a Bot Avatar, resolved over the library's tier walk
by `agentPictureProvider`. An agent's face is chosen in its editor, the circle
at the top being the button: Upload photo (PNG only, a non-PNG pick refused with
a line saying so), a Bot Avatar from the avatar editor, and Remove where there
is one; it is held there and written with the rest of the agent on Save. The
editor shows this project's own face, so one inherited from the default project
shows on the rows but not there. Add, Import and View Bot Avatars are the page's
footer, pinned under the list. The face is `<name>.png` or `<name>.avatar.json`
beside the `.md` — writing one takes the other away — written through
`writeAgentFace` (`data/prompts/agent_pictures.dart`, beside the readers): an
edit keeps the face the agent has, a rename moves it, an import or a replace
leaves the new agent no face of the one it replaced, and a delete takes it with
the agent. The rows re-read it because `agentPictureProvider` watches the
library each write reloads. Add, edit, delete and import reload the library the
moment they are done, the same one way a change to it lands without a restart —
every project's where the page is the global one (the default directory is a
rung of every project's tier walk, so an inherited agent and an inherited
picture go stale everywhere if only `promptLibraryProvider(null)` is rebuilt;
skills keep the same branch), the project's own where it is a project's page.
See "Skills and agents" in `packages/entoli_core/lib/model/AGENTS.md`. **Byte
Repair** is the tooling for the built-in project of the same name: a banner
saying whether the configured terminal env can run it, a button that runs a
bundled install script through that env to put `make`, `github-cli` and ESBMC
into the selected shared rootfs, a button to import a local ESBMC binary into
that rootfs, a button to delete the workspace and all chats in the project, and
the versions found afterwards. "Run Setup" runs the install script and writes a
`.setup-complete` marker — packages stay in the shared rootfs when project data
is deleted. The chat page gates the composer on that marker, showing a "setup
required" bar until it is there; on the host the marker is not enough either,
since the fetched tools live in a cache directory that can be emptied between
setups, so the binary is asked after too. Where the tools land follows the env:
inside a rootfs they go to the guest's own `/usr/local/bin`; on Linux they go to
`<cacheDir>/byte-repair/bin`, which the project's turns are given on PATH — so
Byte Repair works on the host env with no root and nothing installed into the
machine, and a tool already on the machine is used rather than fetched. A mac is
the exception to "nothing installed": its tools come from Homebrew, into the
system, and are linked into the same bin directory. The page says so in a line
above Run Setup, and where no `brew` is installed it shows Homebrew's install
command to paste into a terminal, drawn as a reply's `CodeBlock` so it carries
the same copy button; the setup cannot run that installer itself, which wants
sudo. Both are the store's (`setupNotice`, `prerequisite`), so the page names no
platform. A delete takes the links and leaves what Homebrew installed, and its
confirm says that. While a setup or an import runs, the category cannot be left
(`SettingsCategory.held`): back, the bar's button and another category's tile
are all shut, since the run's log and error are the page's to show. See "Byte
Repair's environment, in five variables" in `lib/data/local/AGENTS.md`. The
banner asks the same env question everywhere, the store naming the platform's
own answer: a phone with no Linux has no shell at all — so both hide the rest
until a rootfs is picked from Terminal, and a setup run by either guest installs
through its own `apk`. The desktops' host shells are each given an install
destination and so are capable. The delete sits below the banner everywhere the
category is drawn, since the workspace and the chats are data wherever the
tooling is not: its confirm message's environment clause is worded by the
store's `environmentDeletion`, asked off the disk rather than assumed off the
platform, so a delete over a project whose setup left nothing behind names the
workspace and the chats alone. **Sync** is paired devices — this device's name,
the paired-device list, and the pairing controls. A pairing never renders
inline: window, invite and pasted code all move to a screen of their own that
ends on a paired screen naming the device, with Pair another device on it — see
"The pairing flows as pages" in `lib/data/sync/AGENTS.md`. A paired device's row
clicks through to its own page (Paired device page,
`lib/ui/settings/paired_device_page.dart`) — the record and a rename, then both
fingerprints under "Device fingerprint" and "This device" with the explanation
of the comparison they exist for. The Sync list itself draws no fingerprint. The
relay and TURN settings are screens of their own behind two rows on the page,
and Keep connected off screen is the phones' row only — the platforms whose
process freezes with the screen (a notification on Android, a Live Activity on
iOS). See `lib/data/sync/AGENTS.md` for the threat
model and handshake. **Providers** is the endpoints — and the keys, which are
not in `settings.json` at all: a key typed into the provider dialog (or the
recommended-provider card) goes to the secret store, under the provider's id,
and the row says "Connected" rather than showing any of it — "Needs a key" where
neither a stored key nor its named variable is there, "On this computer" for a
local server, and an endpoint typed in by hand carries its address in front
(`ProvidersSection`, `provider_settings.dart`), and its X asks before removing
one, since the key and a program's sign-in go with it. Adding one opens
`showProviderPicker` (`provider_picker.dart`), a page of its own: every
preset and every program this platform runs, as a card under its company's
`ProviderMark` (an initial, the model catalog's too, not a logo: Anthropic's trademark terms allow its marks only
in material it approves and forbid recolouring them), with no grouping, every card one size in a centred grid (`_CardGrid`), its
tags scrolling inside it rather than growing it. Above
the cards are two rows of `ToggleChip`s: the `ProviderTag`s (Private, Privacy
controls, Paid, Free), every one picked required, so Free and Private shows
nothing; and the companies, any one picked allowed, since an offer has one
(`ProviderFilter`, `lib/app/settings/provider_filter.dart`). A provider's tags
are read off its `terms`, which also name its company (`maker`); a plan's program is Privacy controls and Paid, its
account settings deciding the training, and a model run here is Private
alone. Custom is a card only while nothing is picked, having no tags. A free
tier is agreed to in a dialog before anything else is asked. Then
`ProviderDialog` opens over the page, which stays until a provider is saved,
so backing out of a sign-in is back to the choice: `ProviderDialog` ("Connect X" for a preset), over a `ProviderEdit`
(`lib/app/settings/provider_edit.dart`), which holds the entry being edited
and builds what is saved: an empty base URL or models.dev id falls back to the
preset's, and an empty name to the preset's name, numbered `-02`, `-03` on
where an entry already has it, the name being what a model is picked by. A preset's dialog is written for someone who has
never seen a base URL: what a key is and a link to make one, the key field as
"Access key" and focused, and the provider's privacy policy, with the technical
fields — name, API, base URL, models, the named variable — folded under
Advanced; an endpoint typed in by hand opens on those alone. Which is which is
the preset's `terms`. A typed key is put to the provider's own `checkKey`
(`checkProviderKey` over `keyCheckProvider`) on Save: a no keeps the dialog
open, said on the key, with Save turned into Save anyway, and a provider that
could not be asked is saved, since no answer is not a no. The key is tri-state —
typed text stores, an empty field over a stored key keeps it, and "Remove saved
key" clears it — because an empty field alone cannot say keep from clear once
the field no longer echoes what is stored. `editProvider` is the one way in, for
the page and for a caller connecting a service by name (`adopt`). The TURN
password is in the store the same way; the TURN username is not a secret and
rides in `settings.json` beside the URL. **LLMs** is what a new chat is answered
by and what names it, and how long that model thinks — `ReasoningEffort`, sent
only to a model the catalog says reasons, since another may refuse the field; a
chat's settings, and the new-chat screen's, can override it in `meta.json`, a
reset beside it putting the chat back on the app's. Under it the **Agent** —
command approval mode and the classifier model, which travel together because
auto mode is unusable without one, and the standing permission rules the agent
consults before any of it — and a **Turns** section — how a turn runs and is
bounded: the retry rounds, the step limit, the Total Context window, the
Auto-compact switch and share, and the Maximum response length, a number that is
a fallback for models of unknown limit or, switched on, a cap on every reply
(see "How long a reply may be" in
`packages/entoli_core/lib/agent/llm/AGENTS.md`). The Agent was under General
until it moved beside the model it runs. How long the model thinks and the image
model's Quality are both a `ThinkingSlider` (see `lib/ui/widgets/AGENTS.md`).
**Memory** is what one conversation leaves the others: the two `AGENTS.md` files
every turn is read from — the user's own at the root of the data directory and
the project's in its workspace — and the ways a turn may keep what they pull in
out: imports and the nested ones found on a read, both on by default, and the
patterns that keep a file out; the built-in projects read a note the app ships
instead of any file. Beside them the memories the app writes for itself, which
the recall, extraction and tools sub-gates and the Memory LLM steer; the profile
pages edit the files — the global page the user's own, the project page the
project's, and no built-in project's — and the memories themselves are looked at
on a page the settings draw. The two halves are "Memory" in
`packages/entoli_core/lib/agent/AGENTS.md`. **Data** is all of it at once, out
as one file and back — see "Backing it all up". **About** is the app rather than
anything it does, which is why it is last — see "What the app is".

## Work folders

A project's settings page has a **Work folders** section: the folders outside
the workspaces that every turn in the project may write to, granted before
any turn so nobody has to be there to answer for them. It is what Claude
Code gets from being opened in a folder. A chat working in a repository
elsewhere on the machine otherwise left the sandbox once a command and
waited on a banner each time, and a turn left running while the user was away
was refused outright.

It is no new store. The rows are the project's `writableDirs` in
`project.json`, the list an `add_directory` "always for this project"
answer already extends. So a folder granted on a banner shows here, one removed
here is gone from the next call (the policy is read per call), and the
sandbox, the approval gate and the file tools all read it through the policy
as they always have. The list stays in `project.json` although it holds this
machine's paths, unlike `instruction_files.json`. The field was already there,
moving it would cost a migration, and a path that reaches another machine by
backup or sync names a folder that is not there, which grants nothing (below).

A folder comes from the platform's picker (`FilePicker.folder`, in
`entoli_files`) and is never typed. It is refused, with a notice, by
`refuseFolder` in `packages/entoli_core/lib/model/work_folders.dart`, the one
test any grant takes, `add_directory`'s banner included. It refuses a path that
is not a directory, the root, the home or anything holding it, the app's own
data tree (the data directory, anything under it, or anything holding it), and
anything holding the project's workspace. A row whose folder that test now
refuses says why under its path (`FolderRefusal.row`). The commonest case is
"Missing on this device", a folder that has disappeared or arrived by sync from
another machine. The turn drops such a folder from its policy as well, so it
grants nothing and a command cannot recreate it under the grant. Rows are the
shared `EditableRow`, with no tap, since a folder is only added and removed.

The folders the sandbox grants by default — the temp folders, the caches, the
toolchains' stores, a repository's `.git` — are not rows here. They are the
app's, not the user's additions, so each is a toggle beside the Sandbox
switch (a `SandboxGrant`; see "Approvals" in
`packages/entoli_core/lib/agent/AGENTS.md`), on unless turned off.

It is drawn only where the paths are this device's and the sandbox is what
they open. It is not drawn for a paired device's project, whose folders a
picker here cannot name. Nor is it drawn where the picked
driver's `Confinement` does not enforce the sandbox: Windows, which confines
nothing, so the list would change nothing (see "What is absent, and honestly
so" in `windows/AGENTS.md`); phones; and a Linux guest.

## The trigger editor

`TriggerEditorPage` (`trigger_settings.dart`), over a `TriggerDraft`
(`lib/app/settings/triggers.dart`), which holds what is edited, says why it
cannot be saved (`refusal`, shown on the page with Save off) and
builds what is saved (`build`): the name, the prompt, and one row of
"When" — a segmented choice over the three sources, each kind bringing its
own fields under it: a schedule its date and time and repeat, a timer its
countdown minutes, a file watch its paths, added one at a time, and its kinds
of change. Beside
them "Address to": the member the fire names, from the trigger's project's
library, or nothing for the whole room — one field for both targets, since
addressing is not a property of where the fire lands. A stored member the
library has since lost keeps its place in the list marked `(deleted)` with
the line saying a fire will reach the whole room, and is kept or exchanged
rather than silently cleared. Each kind keeps its own answers while another
is showing, so switching to Countdown and back loses nothing; a project
deleted since is saved as the default. A `trigger_set` the agent registered
is shown and not saved: the page has no Save, and the list's switch and the
bar's delete are the whole of what is editable, since the prompt is its
conversation's and an edit would be a conversation rewrite from a settings
page.

**The prompt is a `PromptField`**: what
the trigger will send, rendered the way the chat will render it, over the
button that opens its page, shared with an agent's system prompt and the
instructions (see "Shared UI" in `lib/ui/widgets/AGENTS.md`). A trigger is
written once and read many times afterwards, so the page it is read on shows
the message. What is typed in it is `CompletionField`, completing `/skills`
and `@agents` from the trigger's project's library, since a trigger's prompt
is dispatched through it. Leaving the page with something typed asks first
(`TriggerDraft.edited`, under `DiscardGuard`), on the prompt page and on the
editor under it alike.

**Temporary chat names its Default** as the chat settings page's combobox
does: the new chat a trigger makes is a chat, so Default is the project's or
the app's answer, and the pick is written onto `meta.json` as it is.

## What the app is

About is five tiles: the icon the app is wearing beside its name and version,
who made it, a link to the repository, the privacy policy, and the libraries.
It is `about_settings.dart`, beside the keyboard shortcuts.

The version is read out of the bundle rather than written into Dart, so
pubspec's number stays the only one. `tool/prepare.sh` writes `version.json`
from pubspec's `version:` and it is declared as an asset, so every platform's
bundle carries it; Flutter writes its own `version.json` for Linux, which
overrides ours there, and on every other platform ours is the only copy.
`platform.appVersion` reads it, and composing the string is shared. It is awaited into the container in `main` beside the ABI,
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
for an install time nothing shows — for one field of a file this reads
directly.

The libraries are Flutter's own `showLicensePage`, not a list kept here. The
registry already holds every package that ships, and the app adds its own
AGPL (`registerAppLicence`, the entry the welcome tour shows) and the bundled
font and voice licences to it — see "How a reply is set" and "What listens and
what speaks", both of which were written against a licence page that did not
exist yet. The bundled skills join them one entry per skill that carries its
own `LICENSE.txt`, named after the skill and read from the embedded data —
`registerBundledSkillLicences` — so the notice travels with the skill wherever
the skill is redistributed, which is what a licence like skill-creator's
Apache asks.

**Narrow, the categories are the page rather than its drawer.** The page is a
`SidePanelFrame` like the chat's, with `SidePanelNarrow.page` where the chat
has `drawer`: below `navBreakpoint` the list is the whole window and a picked
category is drawn in front of it, left by the bar's back button or the back
key. That is the one place this and the chat page differ about what a panel
becomes, and the difference is what is underneath: the sidebar opens over a
conversation, which is what the user came for, while a drawer here opened over
General with the other categories behind a hamburger — the structure of the
page, reachable only by knowing it was there. So settings opens on the list,
with no menu button anywhere; the bar's leading slot is always a back button,
out of settings from the list and to the list from a category.

General is selected until something else is picked, so a wide window has it
beside the list and a narrow one has it highlighted there. `_categoryBody` is
what both layouts draw, at the same place in the frame's tree, so crossing
the breakpoint keeps the category and whatever it holds: `_category` is the
pick and `_categoryShown` whether it is in front of the list when narrow,
kept at either width, so narrowing after a pick lands on that category and
widening puts it beside the list. A named `initialCategory` opens in front of
the list; with `focus` it is the whole page and nothing else.

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
keyring is a machine's own). Unless the user asks: **Include provider keys**,
a switch under the two buttons and off by default (`backupProviderKeys`), puts
each provider's key in the zip as `backup-keys.json`, a member beside the
manifest rather than a file of the data directory, and a restore hands them to
the secret store once the files are back. The switch says what it costs:
anyone holding the file can spend the keys.

A per-project `rootfs/` is the one re-fetchable tree that may still live under
the data directory, left by a build whose built-ins kept their own living
filesystem there beside the chats; nothing writes one now. `writeBackup`'s
`skipDir` leaves it out for the same reason the voice models are outside it,
and for a second one: proot's
mode-0000 bind stubs (see `tree_ops.dart`) sit inside it, and `dart:io` cannot
list a mode-0000 directory, so a walker that reached one would throw. The
directory a restore replaces goes through `removeTree` rather than a plain
recursive delete, so the stubs a skipped `rootfs/` leaves behind go with it —
the same `removeTree` the rootfs stores use, so the one function that knows how
to delete a stub-bearing tree is the one the restore reuses.

**A link is followed only into a project's workspace.** One that lands
anywhere else — out of the data directory, into `sync/`, or nowhere — goes in
as the link and nothing it leads to, and the restore puts the link back
(Windows lets a user make one only with a privilege they often lack, so there
it is a line and no link). Where it lands is its real path against the data
directory's, resolved once, since the data directory may itself sit under a
link. The zip writes a link as a Unix `zip` does, target as content and
link type in the mode; `linkTargetOf` reads it back, since the encoder marks
every zip MS-DOS and its own decoder then finds no link in one.

**A restore is unpacked beside the data directory and swapped in.** The members
go into `<dataDir>.restoring`, the `machineLocalFiles` are copied across from
the live directory, and the migrations run there; then two renames put the live
directory at `<dataDir>.replaced` and the restored one in its place, and the
replaced tree is deleted. Until the first rename nothing of the data directory
has been touched, so a restore that fails on the way — a member that will not
write, a full disk, a backup file that went away — leaves the app exactly as it
was rather than half cleared. A process killed between the two renames leaves
no data directory beside a whole `.replaced` one, which `AppConfig.load` renames
back; leftovers of either name are cleared by the next restore before it
starts. The sibling is what makes the swap a rename: one filesystem, no copy.

`AppConfig.machineLocalFiles` are the top-level files a backup skips and a
restore leaves where they are, one list both read so the two cannot drift.
Today it is `instruction_files.json`, which holds paths on this machine (see
"Workspace instructions" in `packages/entoli_core/lib/agent/AGENTS.md`) that
name nothing on another; restoring an older backup should not unlink what was
linked since.

It was one JSON document holding every file first, and that is worse on every
count that matters. Text in JSON is escaped inside a string inside an array,
binary costs a third more as base64, and nothing compresses, where deflate takes
`conv.jsonl` to a fraction of itself. The one thing JSON was better at, saying
what the document is before anything is deleted for it, a member gives back.

Both directions stream, so a backup costs disk rather than memory.
`writeBackup` walks the data directory into a `ZipFileEncoder` (`zipTo`, the
walker the workspace share uses too), a member read and compressed at a time.
`BackupHandoff.save` takes a name and a writer rather than a file: the desktop
asks where first and the writer zips straight there, so nothing is written
twice and nothing at all on a cancel, which `save` answers false and the page
then says nothing; Android writes to a temporary directory and shares from it.
`openBackup` decodes the picked file's directory alone and leaves the members in
it; the restore opens it again by path on an isolate of its own — an open file
does not cross — and decompresses each member straight into its target file,
so a large one holds up no frames; `writeBackup` compresses on one the same way.
The file stays open until `Backup.close`, which the settings page owes whether
or not the user agreed. A backup saved inside the data directory needs nothing
special: the restore reads every member before the swap touches the directory.

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
and a chooser to get one back. Each platform's answer is "A backup's way out"
in `packages/entoli_files/lib/AGENTS.md`.
