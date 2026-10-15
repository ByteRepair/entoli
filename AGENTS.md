# Entoli

Flutter (Linux/Web/Android/iOS/macOS) ChatGPT-style UI over a coding agent. Client-side:
it calls the user's own LLM endpoints and runs commands on their machine.

The app is named Entoli; most of the identifiers are not, and deliberately.
The data directory is still `~/.config/agent-chat`, the env var is still
`AGENT_CHAT_CONFIG`, and the Dart package is still `agent_chat`. Renaming any
of those would leave the chats already written where nothing reads them, for a
string nobody sees.

The application id is `io.byterepair.entoli` — the Android `applicationId` and
`namespace` and the Linux `APPLICATION_ID`, all one string. Changing it makes
this a different app to Android, which is only free before a release; it is why
the Kotlin package moved with it.

## Where the rest of this is

The rest of these notes live in the directory they are about, so each one
loads when that code is being read rather than on every session. A section
named in a cross-reference is findable from this list.

- `lib/domain/AGENTS.md` — The conversation log, Threads, The projection,
  Carrying on an interrupted turn, Starting a chat, and naming it, Skills and
  agents, Resending a message, Attachments, Reminders
- `lib/ui/sidebar/AGENTS.md` — The sidebar's list, Pinned chats
- `lib/ui/marketplace/AGENTS.md` — The marketplace page
- `lib/data/builtin/AGENTS.md` — The agent loop, Running the commands, Running a
  command yourself, Approvals, Questions, Sub-agents, Their own transcripts,
   Carrying one on, Web search, Skills, The plan, Memory
- `lib/data/builtin/llm/AGENTS.md` — Reaching a provider, Errors, and how long
  the UI waits
- `lib/data/sync/AGENTS.md` — The threat model, the handshake, the framing
  layer, three rendezvous transports, the SyncHub, mirroring a chat, control
  and driving a turn from the other end, what the Sync page can do about a
  peer, secrets at rest
- `lib/data/local/AGENTS.md` — Bundled tools, A whole Linux under proot,
  Running a model on the device
- `android/AGENTS.md` — Staying alive off screen, The workspaces in the Files
  app, Being the assistant, Waking for a trigger, The app icon, The debug
  build's own
- `ios/AGENTS.md` — The icon, Export compliance, Privacy declarations, Why no host shell, The iSH driver, The rootfs,
  The workspace inside the guest
- `macos/AGENTS.md` — Why no sandbox, The entitlements, What a command runs on,
  What is absent, and honestly so, Voice mode, The icon, The DMG, Tests on
  this host
- `macos/Runner/entoli.icon/AGENTS.md` — the app icon's Icon Composer package:
  the layers, what the build does with them, and the Liquid Glass format notes
- `windows/AGENTS.md` — The exe and its icon, The MSI, What is absent, and
  honestly so, and nothing Windows runs on this host
- `lib/ui/chat/AGENTS.md` — When a turn is over, Thinking and tool runs,
  Selecting a reply, and copying it, How a reply is set, Code blocks, A command
  the user ran, A chat whose home device is elsewhere, The chat page
- `lib/data/voice/AGENTS.md` — Voice mode, What listens and what speaks, The
  Android system engines, Which language it is asked in, Ending the utterance,
  What counts as being spoken to, One listener, two engines, Mute is the user,
  not the conversation, Per side, not per session, The Kotlin, Where the models
  live, Hearing and speaking
- `lib/ui/voice/AGENTS.md` — Reading one message out, The screen, Touch to
  speak, Taking turns
- `lib/ui/workspace/AGENTS.md` — The workspace explorer
- `lib/ui/share/AGENTS.md` — Sharing to Entoli
- `lib/ui/AGENTS.md` — Opening a link, The theme, What the settings page can
  change about it, The keyboard and the caret
- `lib/ui/settings/AGENTS.md` — Setting overrides, What the app is, Backing it
  all up
- `lib/ui/widgets/AGENTS.md` — Shared UI, A catalog of things to download
- `.github/workflows/AGENTS.md` — Releasing
- `tool/linux/AGENTS.md` — The Linux AppImage
- `test/AGENTS.md` — how the tests are written and what they fake

## Architecture

One backend, `BuiltinBackend` — the built-in agent, running in this process. No
server, no Python, nothing to install. `AgentBackend` stays as an interface so
the UI and repository can be tested against `FakeBackend`.

It is called *builtin* rather than *miniswe* because the loop is no longer
mini-swe-agent's in any sense a name should claim: see "The agent loop" for what
is still shared and what is not. `built-in` was the word when there were two
backends and one of them was an OpenCode server; with one backend it contrasts
with nothing either, which is why nothing user-facing names it at all.

- `conv.jsonl` is the source of truth, and it is a log rather than a document.
  `ChatController` appends a turn's events to it as they arrive;
  `ChatRepository` resolves which model runs and owns rewinding. Context is
  re-injected only when a turn is resent — otherwise the agent's own session
  carries it.
- The agent runs **on top of** Entoli. Skills and agents are Entoli's,
  resolved where the message is composed and recorded on it, so the model reads
  the same words on every reading of the conversation.

### On-disk layout

`<dataDir>/projects/<project>/` holds `chats/`, `workspace/` and `memory/`,
the project's memories beside what its chats share, and `project.json` — the
project's own overrides: the temporary-chat TTL, the command environment its
chats run under, and whether it keeps an auto-memory store of its own. A chat is
`chats/<chat-id>/` with `state.json`, `conv.jsonl`, `meta.json`, `resources/`
and `subagents/` in it; where its commands run is `workspace/chats/<chat-id>/`,
inside the workspace the project shares rather than beside the conversation.
Every project is a directory under `projects/`, the default one included.
`<dataDir>/projects/<project>/skills/<name>/` is a skill — a directory with a
`SKILL.md` and the files it runs with, not a single file, the frontmatter held
to the Agent Skills spec (see "Skills and agents" in `lib/domain/AGENTS.md`;
a folder that does not conform is skipped at load and said on the view page) —
and `<dataDir>/projects/<project>/agents/*.md` are that project's agents. The
default project's skills and agents are the base set every other project
inherits; another project's own replace a same-named default entry for that
project alone. An Omada-on project has My Team's rung between the two: its
agents are the default set, My Team's on top, its own above those — the
chain `default` < `my-team` < the project, and only for agents, since My
Team ships no skills. The bundled skills and agents live in the binary:
`tool/gen_bundled_skills.dart` writes them, build-time, from
`assets/prompts/projects/<project>/` — the locally written skills and agents —
and from `build/skills-upstream/` into
`lib/data/prompts/bundled_skill_data.dart`, tagged with the project they
belong to, so the library the model reads cannot be poisoned from the skills
directory and a project sees only what it is meant to (esbmc-verifier is
byte-repair's alone).

**The presets are completed from a release, not a pin.** `tool/fetch-skills.sh`
resolves the latest release of `ByteRepair/skills` — our fork, where the
wording fixes are made — and extracts its tarball to `build/skills-upstream/`,
its cache keyed on the tag so a new release flows in on the next `prepare.sh`
with nothing edited. The generator copies what the release ships wholesale and
unscoped, skipping only names the source tree already carries: what ships is
the fork's release decision — its `RELEASE_EXCLUDED` and `tool/release.sh`,
which prune, reword Claude to Entoli and check the result when cutting a tag —
not ours, and the one rule kept here is a tripwire: a fetched skill with no
`LICENSE.txt` says so on stderr, and a test refuses any fetched skill whose
licence is not Apache. A skill's own licence is registered per skill for the
licence page (see "What the app is" in `lib/ui/settings/AGENTS.md`), and a
file that is not text at all — a font, an archive — is embedded base64 beside
its text siblings (`BundledPromptFile.binary`), which the self-heal and the
export read back as bytes.
`<dataDir>/projects/<project>/skills-bundled/` is a read-only copy of that
project's bundled skills on disk, there only so `bash` can reach a skill's
scripts (which want a real base directory); it is self-healed from the
embedded data at startup — a file that drifted is re-written by checksum, and
a stray the embedded data does not name is deleted. It is beside `skills/`
rather than in it, so deleting one's own skill does not reach the presets.
`settings.json` holds the app-level model default, the
title model, the classifier model, `approveMode`, `environment`, `appIcon`,
`appTheme`, what the palette is built from — `primaryColour`, `secondaryColour`,
 `cornerRadius` and `systemPalette` — and `llmProviders`, whose entries carry
no key: the provider API keys and the TURN password live in the secret store
beside the sync identity (`AppSecrets`), which is what keeps them out of
`settings.json` and out of every backup zip; and the user's
 global `AGENTS.md`, the instructions that reach every turn in every user
 project, beside it.
`<dataDir>/reminders.json` is the user's triggers — reminders generalized to
schedule, timer and file sources — one JSON list; the boot receiver reads it
with no engine running, which is why writes go through a rename. The file name
is the reminder's and stayed, a rename being a migration.
Data dir: `$AGENT_CHAT_CONFIG` if set, else `~/.config/agent-chat` (desktop),
app-private storage (Android), and `/agent-chat` in a browser — where it is a
name in IndexedDB rather than a path, and load-bearing all the same.
`AppConfig` is not the only thing that knows this layout: `WorkspaceProvider`
reads the workspace half of it in Kotlin, because Android's Files app asks with
no engine running. See "The workspaces in the Files app".

The filesystem is a port, and it is `fs_shim`'s `FileSystem` rather than one of
ours: `fileSystemIo` on desktop and Android, `fileSystemWeb` (IndexedDB) in a
browser. Declaring an interface over it would have been the same members twice.
`AppConfig` holds one and composes path names against it — `dataDir` and every
helper are plain `String`s now, since the `dart:io` `File` and `Directory` they
used to return were unusable on the platform that needed them most. The one
question a `FileSystem` does not answer is where this platform keeps things,
and that stays in `core/platform/`.

The whole layout is in it, prefs included: `settings.json` on the web is
`/agent-chat/settings.json` in IndexedDB, the same path it has on a disk. What
that costs is the synchronous read — `fs_shim` has no sync methods anywhere,
deliberately, because a browser cannot have them. `AppSettings.load` and
`ProjectSettings.load` need one: the shell asks for the environment on every
command and the registry for the providers on every model call. So `Documents`
holds those two kinds of small JSON file in memory, hydrated in `main` before
`runApp` and written through on save. Nothing else gets a copy; everything else
reads through, async. The cost is that a file edited behind the app's back is
not picked up until a restart, where it used to reach the next command.

Writes go through a rename. `writeAsString` truncates and only then writes, so a
read landing between the two finds an empty file — and the title call renames a
chat while a turn is writing beside it. A serialising queue was the other answer
and a worse one: it made a read wait on a write, which deadlocks a widget test
where only pumping advances the fake clock. This is for the documents;
`conv.jsonl` is appended to and has its own answer to the same hazard.

The web filesystem is paged (`FileSystemIdbOptions.pageDefault`), which the
`fs_shim` default is not. Unpaged, a file is one IndexedDB value and an append
reads the whole thing back to rewrite it, which is the opposite of what a log is
for. Page size is per file and converted on the first write, so nothing has to
be migrated.

Chats are a `ChatStore` — a whole store rather than four calls — and there is
one implementation, `FileChatStore`, because the layout no longer varies.
`DirectoryPrompts` is the same: it reads the config's filesystem, so the user's
own commands and agents exist on every platform. Neither is chosen per platform
any more; `core/platform/` builds both once.

None of this is checked by loading a tab — see `test/AGENTS.md` for how the
browser's filesystem is exercised on the VM instead.

### Migrations

**A release that moves anything under `<dataDir>` carries a migration, in the
same PR as the move.** `lib/core/migrations.dart` is where it goes: `migrations`
is a chain, oldest first, and each entry is written against the layout the entry
above it leaves and nothing older. A directory several releases behind is
brought up by running the entries after it in order — 0.1.2 to 0.1.3 to 0.2.0 to
1.0.0 — so no entry has to know every shape the directory has ever had. Name it
by the version being released, which is `pubspec.yaml`'s and nothing else; see
"Releasing".

`<dataDir>/version` holds the release whose entry last ran. It is not the app's
version: a release that leaves the layout alone leaves this where it was, so
what it names is always an entry in the chain. A data directory this launch
created is stamped with the end of the chain and nothing runs over it; one with
no stamp at all is older than every entry and gets the lot. A stamp naming no
entry this build has is a directory written by a newer build, and it is left
exactly as it is. `AppConfig.load` runs the chain, and so does `restoreBackup` —
a backup unpacks the layout of the build that made it, stamp included.

Three rules for writing one. **An entry that has shipped is never edited**: an
installed copy has already run it and will not run it again, so a change reaches
only the directories that were behind. **An entry spells its paths out** — it is
handed a filesystem and the data directory rather than an `AppConfig` for that
reason, since `workspaceDir` answers for the layout this build has and an entry
is about one that is gone. **An entry does nothing where what it moves is not
there**, because it also runs over restored backups and over directories where
the user deleted whatever it was looking for. Two things have changed the layout
since 1.0.0, and neither is in the chain: the user's `commands/` became
`skills/` — a private app with no released directory to carry forward, so a
`commands/` left on disk is not read rather than migrated — and `memory/`, a
directory created on first use rather than moved. The chain stays empty.

### Artifacts

`chats/<id>/artifacts/<artifact-id>/` holds the files the model published,
copied from its workspace at the moment it called the `artifact` tool, with the
base stylesheet (`lib/domain/artifact_style.dart`) injected into the entry file
**at publish time**. That timing is the one load-bearing fact: the desktop
opener serves the directory itself over `file://`, so the entry file on disk
must already be the whole page — the model's `read` tool and every future
reader see the same styled file, and a temp copy at open time would break every
relative reference to the files beside it. Android and the web still layer
their runtime paths (an HTTP server, blob URLs) over the same injected copy,
where the marker makes the second injection a no-op. Artifacts published before
the injection moved open unstyled on desktop until the model re-publishes them.

An artifact of a mirrored chat has no local directory to open: the sync hub
carries the whole artifact as one zip over the ordinary resource channel (see
"Attachments" in `lib/data/sync/AGENTS.md`), `unzipRemoteArtifact` writes it
to a temp directory, and the local paths above take it from there. That
staging is a port (`RemoteArtifacts` under `core/platform/io/`, the hub
reached through a one-method interface), not a page: it owns the temp
directories' lifecycle, where the previous one for the same chat and artifact
goes only when the next one has checked out. A re-publish invalidates the
fetched zip the moment its record lands. The web is the exception — it opens
the local blob-URL path only, and a browser mirror says so rather than
fetching.

### Projects

A project is a directory holding its own chats, one workspace they share, and
its memories.
The default project is `null` above the filesystem and `projects/default/` below
it — one shape for every project rather than one project that is also the data
directory. `AppConfig`'s path helpers all take `{String? project}`, and passing
nothing means the default. `isProjectName` refuses `default` for the same
reason: a second way to name it would be a second entry for it in every list.

A **built-in project** is a directory the app ships rather than the user makes,
declared in `builtin_project.dart` (`builtinProjects`, today `anonymous`,
`my-team` and `byte-repair`).
It is a project in every respect that matters to the store — same layout, same
movement, a chat can be in one — but its name is refused by `isProjectName`, so
it cannot be created, renamed or deleted, and `everyProject` is where it is
offered. What is special about it is what a *turn* in it may not have, and that
 is a `BuiltinProject` spec: which profile it runs under (`ProfilePolicy`),
 whether project memory runs (`MemoryPolicy`), whether its workspace is shared
 between its chats, which capabilities it takes away, whether it opts into
 rootfs isolation, whether it requires a setup step before turns can be sent,
 and, where it ships
 one, a note that stands in for the instruction files. `anonymous` turns all
 of the first four off and is the one that ships a note: no profile, no
 memory, a workspace it does not share, and its own account of what an
 anonymous chat is, embedded at build time from
 `assets/prompts/projects/<project>/system/` (`tool/gen_prompts.dart`) rather
 than anything on the user's disk —
 so the context and tools that would reach another conversation are simply not
 there. A turn never meets a built-in project itself:
 `ChatRepository._turnSettings` resolves the spec into a profile, a memory, a
 `sharedWorkspace` flag, a `disabled` capability set and the bundled note, and
 the backend sees only those.

Two workspaces reach a turn, and they answer different questions. The project's
(`<project>/workspace/`) is where work another conversation should find goes,
and it is the `HOME` of every command where a command gets a project's home at
all — inside a guest, whose own home is one directory every project would
share, and on Android, where the app has no real user home to give — so a
repository cloned, a package installed or a `~/.gitconfig` written by one
conversation is already there for the next, and one project is one environment;
on the desktops the machine's own `HOME` stands, shared by every project, and
`~` in a command is the user's real home. The chat's own is a folder *inside*
the project's (`<project>/workspace/chats/<id>/`) and is the working directory
every command starts in — the shell that runs them keeps whatever directory a
command moved it to, one per chat; see "Running the commands". What a chat *is*
— the log, and what was attached to it — stays in `chats/`, which the agent is
never given a path to. A file-tool path may be prefixed `project:` to name the
project's workspace explicitly or `chat:` to name the chat's own; `~` follows
`HOME`, so on a desktop it lands past the workspaces and is gated like any
absolute path out.

`moveChat` therefore moves two directories, and `delete` removes two.

`ChatStore` is addressed by chat id alone, so `FileChatStore` is what knows
where a chat is: `_locate` answers from a cache that `list` fills, and falls
back to looking for the id under each project. It returns a record rather than a
name because "in the default project" and "nowhere yet" are both `null` and mean
opposite things to a save. Where a chat already is wins over what its
`ChatState.project` says — a UI copy held from before a move must not write the
chat back where it used to be — and the field only decides where a chat that is
nowhere yet goes. Reading is the same rule: `list` and `load` stamp each chat
with the directory it came out of, so one moved by hand is in the project it was
moved to.

`ChatRepository.sendPrompt` resolves the project the way it resolves the model,
and it travels to the backend as a `sendPrompt` parameter. A draft answers for
itself: it is not on disk to be found, and its first turn can be sent before
anything has written it.

The sidebar shows one project at a time. `chatListProvider` holds every chat, in
every project — the store reads them all in one pass — and the sidebar filters
on `selectedProjectProvider`, which is also where a new chat goes. Switching
projects clears the selected chat, since it is no longer in the list.

A project name is a directory name, so `projectNameFrom` makes what was typed
safe to be one — the model writes paths into it — and `AppConfig.projectDir`
refuses anything that is not one segment under `projects/`, since every
project-scoped path is built through it. That refusal is `isProjectDirName`,
the shape alone; the default project's and the built-ins' names have it too, a
chat can be in one, so path construction accepts them. `isProjectName` is the
shape minus the names the app ships — the default's and the built-ins' — and is
where a user names a project: a directory that could not have been created as a
project is not listed as one, so a stray `.git` beside them is not a project
with no chats in it.

## The automatic update

A desktop build replaces itself with the release the newest tag names. The tag
comes from `https://github.com/ByteRepair/entoli/releases/latest` — the page's
own URL, the tag read out of where its redirect lands, no API and no rate
limit — and is compared against the running version by
`versionIsNewer`. Everything is `lib/domain/app_update.dart` and
`core/platform/io/update.dart`: the pure decisions (repo, the three asset
names, the comparison) in the domain, the platform half — where a download is
staged and what putting a build in place means here — behind
`AppUpdateHost`.

The switch is Settings > General > Update, one app-level bool in
`settings.json`, **on by default and written only when off**, so a settings
file from before it says nothing and gets the on default. The row shows on
exactly the platforms the port serves — `appUpdateHostProvider`, overridden in
`main` beside the rest of the platform ports; `UnavailableAppUpdateHost`
everywhere else, which is why no phone sees a row. The check itself runs in
`main` at startup, unawaited: the tag is a network round trip and a release a
download, and nothing waits on either.

What "put in place of this one" means is the one thing the platforms disagree
about:

- **Linux renames the AppImage file over `$APPIMAGE`**, the one this process
  runs from. POSIX takes a name out from under a running binary; the old inode
  keeps this process alive, and the next launch execs the new file.
- **macOS swaps the bundle.** The image mounts for the `.app` inside it, which
  `ditto` copies beside the running bundle — the engine directory checked
  non-empty first, since a swap is the whole of the app — and two renames put
  it in: old moved aside, new into the old name, the old put back if the
  second rename fails. The aside stays for the stale sweep a day later, this
  process possibly still reading from the bundle it just left.
- **Windows installs over itself.** A running exe cannot be renamed and the
  release ships an installer, so the check arms one: a detached PowerShell
  waits for this process to exit, then starts `msiexec /i
  entoli-installer.msi /qn /norestart` under `Start-Process -Verb RunAs` —
  the UAC prompt the user sees at quit. RunAs is what raises it: silent mode
  suppresses the elevation prompt itself, and a per-machine install that
  cannot ask fails with nothing to say so. The next launch is the installed
  upgrade.

Nothing is put in place before the download has arrived whole — the bytes are
counted against the length the response declared, the one truncation being the
one that arrives as success — and a check that dies at any point takes its own
staging back. The check runs once per process, not once per session: a restart
a restore builds is this process still running, and a second check would arm a
second Windows exit-waiter over the first's. A debug or profile build checks
nothing, a Linux not running from an AppImage checks nothing, and a check
whose network is not there gets one `logFailure` line and no second try.

## Saying what it did

**Anything the app catches and carries on from gets a line.** Not a trace of
what it is doing — a line where something did not work and the user cannot see
it any other way. A failure that is caught and dropped, and there are good
reasons to drop most of them, is otherwise indistinguishable from nothing
having happened: sync shipped with nine such places and "it will not pair"
came with nothing at all to go on, in a log or on screen.

`logFailure` in `lib/core/log.dart` is how: a `[tag]` prefix naming the layer,
one line, the reason and enough to say which thing it was about. Nothing calls
`debugPrint` directly, so a log reads the same whoever it is sent to.
`syncLog` is a wrapper over it, since nine call sites read better for one.

Three rules for what goes in one.

**Failures, not traffic.** A log of everything that happened is unreadable and
nobody sends it. What earns a line is the arm nothing draws: a send that
threw, a file that would not parse, a request nobody answered, a plugin that
refused.

**Nothing that should not leave the machine.** No secrets or keys, no message
or file contents, no prompt, no model output, no SDP. A user pastes a log into
an issue without reading it; assume this one will be. An id and a reason.

**Failures are not gated on `kDebugMode`, chatter is.** A release build has to
be able to say why it did not work, since that is the build a user is running
when they tell you it did not. Volume — a subprocess's output, a cache hit —
is `logDetail`, which is debug-only.

## Development

- Build/test Linux desktop inside the `flutter-dev` toolbox (host lacks
  cmake/ninja/clang++): `toolbox run --container flutter-dev flutter build linux --debug`.
- UI runs forwarded to host: `toolbox run --container flutter-dev flutter run -d linux --debug`.
- Web: `toolbox run --container flutter-dev flutter run -d web-server --web-port 8087 --web-hostname 127.0.0.1`.
  Nothing runs the app in a browser here, so a web-only regression in the UI is
  caught by reloading the page.
- Voice mode on Linux needs `parecord` (`pulseaudio-utils`) or `pw-record`
  (`pipewire-utils`) on `PATH`; with neither, a session fails to start with a
  message saying so rather than hearing nothing.
- Package the Linux build:
  `tool/linux/make-appimage.sh build/linux/x64/release/bundle dist/entoli.AppImage`.
  Needs no toolbox; it downloads `appimagetool` itself.
- macOS builds on this host natively: `flutter build macos`, packaged by
  `tool/macos/make-dmg.sh build/macos/Build/Products/Release/Entoli.app dist/entoli.dmg`.
  See `macos/AGENTS.md` for the entitlements decision and what signing adds.
- Windows: nothing on this host builds or runs it. The `flutter build windows`
  and the MSI are `release-build.yml`'s windows job (`windows-latest`); test
  the chain by dispatching that workflow with no tag rather than waiting for
  one. See `windows/AGENTS.md`.
- Bundled tools (Android's proot and llama.cpp): `ANDROID_NDK_ROOT=$HOME/.android/ndk/<version>
  tool/android/build.sh arm64-v8a` then `tool/android/stage.sh`. None of it is run
  by the app build; without them an APK has no way to run a Linux and no model
  server. The llama.cpp half needs cmake and ninja, so the `flutter-dev`
  toolbox, and is built for arm64 alone. `$HOME` rather than `~`: a tilde is not
  expanded as an argument to `env` or inside quotes, and the build then fails on
  a literal `~`.
- iSH (iOS's emulator): `tool/ios/ish/build.sh`. The iSH source is a git
  submodule (shallow) at `tool/ios/ish/src/`; the build inits it and its
  `deps/` submodules, then compiles the core (libarchive included), the FFI
  bridge, and the i386 vdso into an XCFramework. Needs macOS, Xcode, and
  LLVM's clang/lld (brew install llvm) for the vdso. Not run by the app
  build; without it an iOS build has no shell to run commands in. `git
  submodule update --init
  --recursive` fetches the source — a clone without it has an empty `src/`.
- The Linux model server: `tool/linux/build-llama.sh`, native (no toolbox —
  host cmake, ninja and glslc), sharing the pin in `tool/android/versions.sh`.
  Stages into `build/llama/`, which `linux/CMakeLists.txt` installs into the
  bundle when it is filled; a build that skipped it still builds and says what
  it is missing.
- git is no longer among them. The agent gets it from `apk` inside the Alpine
  rootfs, which is a distribution's job to patch rather than ours — so a device
  with no rootfs installed has no git.
- The NPU wants Qualcomm's SDK: `tool/android/setup.sh` fetches it into
  `tool/android/toolchains/` against a pinned SHA-256 and `build.sh` finds it
  there. CI runs it too, so what a release ships is what this builds. Only the
  NPU is gated on it: the build always carries the CPU and the Vulkan GPU
  backend, so a build without the SDK still accelerates most phones, and the
  settings page says the device has no accelerator only when it has neither an
  NPU nor a Vulkan-1.1 GPU — see "What the NPU actually is".
- Setup: `tool/prepare.sh` — packages plus codegen. The generated sources are
  not in the repository, so a fresh clone does not compile until it has run,
  and it wants running again whenever a `@freezed` or `@JsonSerializable` type
  changes. `dart run build_runner watch` is the answer while editing
  `lib/domain/`. CI runs the script through `.github/actions/flutter-setup`.
- Analyze: `flutter analyze`. Tests: `flutter test` — see `test/AGENTS.md`.
- The repo is not `dart format` clean and is not meant to be; match the file you
  are in rather than reformatting it.

## Dependency note

Freezed 3.x requires `abstract class Foo with _$Foo` (not just `class`).
Build runner capped at `^2.15.1` to stay compatible with freezed 3.2.5's
analyzer constraint. riverpod_generator dropped due to analyzer conflict with
freezed; we use manual Riverpod providers.
