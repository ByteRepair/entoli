# Entoli

Flutter (Linux/Web/Android) ChatGPT-style UI over a coding agent. Client-side:
it calls the user's own LLM endpoints and runs commands on their machine.

The app is named Entoli; most of the identifiers are not, and deliberately.
The data directory is still `~/.config/agent-chat`, the env var is still
`AGENT_CHAT_CONFIG`, and the Dart package is still `agent_chat`. Renaming any
of those would leave the chats already written where nothing reads them, for a
string nobody sees.

The one identifier that did move is the application id, from the placeholder
`com.agentchat.agent_chat` to `io.github.yiannis128.agent_chat` — the first was
a reverse-DNS name for a domain nobody here owns. Android and GTK both refuse a
hyphen in an id, so the last segment is `agent_chat` rather than `agent-chat`.
It is the Android `applicationId` and `namespace` and the Linux
`APPLICATION_ID`, all one string. Changing it makes this a different app to
Android, which is only free before a release; it is why the Kotlin package
moved with it.

## Where the rest of this is

The rest of these notes live in the directory they are about, so each one
loads when that code is being read rather than on every session. A section
named in a cross-reference is findable from this list.

- `lib/domain/CLAUDE.md` — The conversation log, Threads, The projection,
  Carrying on an interrupted turn, Starting a chat, and naming it, Commands
  and agents, Resending a message, Attachments, Reminders
- `lib/ui/sidebar/CLAUDE.md` — The sidebar's list, Pinned chats
- `lib/data/builtin/CLAUDE.md` — The agent loop, Running the commands, Running a
  command yourself, Approvals, Questions, Sub-agents, Their own transcripts,
  Carrying one on, Web search
- `lib/data/builtin/llm/CLAUDE.md` — Reaching a provider, Errors, and how long
  the UI waits
- `lib/data/local/CLAUDE.md` — Bundled tools, A whole Linux under proot,
  Running a model on the device
- `android/CLAUDE.md` — Staying alive off screen, The workspaces in the Files
  app, Being the assistant, Waking for a reminder, The app icon, The debug
  build's own
- `lib/ui/chat/CLAUDE.md` — When a turn is over, Thinking and tool runs,
  Selecting a reply, and copying it, How a reply is set, Code blocks, A command
  the user ran, The chat page
- `lib/data/voice/CLAUDE.md` — Voice mode, What listens and what speaks, The
  Android system engines, What counts as being spoken to, Mute is the
  microphone and nothing else, Per side, not per session, The Kotlin, Where the
  models live, Hearing and speaking
- `lib/ui/voice/CLAUDE.md` — Reading one message out, The screen, Touch to speak
- `lib/ui/workspace/CLAUDE.md` — The workspace explorer
- `lib/ui/share/CLAUDE.md` — Sharing to Entoli
- `lib/ui/CLAUDE.md` — Opening a link, The theme, What the settings page can
  change about it, The keyboard and the caret
- `lib/ui/settings/CLAUDE.md` — Setting overrides, What the app is, Backing it
  all up
- `lib/ui/widgets/CLAUDE.md` — Shared UI, A catalog of things to download
- `.github/workflows/CLAUDE.md` — Releasing
- `linux/packaging/CLAUDE.md` — The Linux AppImage
- `test/CLAUDE.md` — how the tests are written and what they fake

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
- The agent runs **on top of** Entoli. Commands and agents are Entoli's,
  resolved where the message is composed and recorded on it, so the model reads
  the same words on every reading of the conversation.

### On-disk layout

`<dataDir>/projects/<project>/` holds `chats/` and `workspace/`. A chat is
`chats/<chat-id>/` with `state.json`, `conv.jsonl`, `meta.json`, `resources/`
and `subagents/` in it; where its commands run is `workspace/chats/<chat-id>/`,
inside the workspace the project shares rather than beside the conversation.
Every project is a directory under `projects/`, the default one included.
`<dataDir>/commands/*.md` and `<dataDir>/agents/*.md` are the user's own prompt
files, beside `settings.json` — which holds the app-level model default, the
title model, the classifier model, `approveMode`, `environment`, `appIcon`,
`appTheme`, what the palette is built from — `primaryColour`, `secondaryColour`,
`cornerRadius` and `systemPalette` — and `llmProviders`.
`<dataDir>/reminders.json` is the user's reminders, one JSON
list; the boot receiver reads it with no engine running, which is why writes go
through a rename.
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

None of this is checked by loading a tab — see `test/CLAUDE.md` for how the
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
the user deleted whatever it was looking for. Nothing has changed the layout
since 1.0.0, so the chain is empty and there is no entry to copy.

### Projects

A project is a directory holding its own chats and one workspace they share.
The default project is `null` above the filesystem and `projects/default/` below
it — one shape for every project rather than one project that is also the data
directory. `AppConfig`'s path helpers all take `{String? project}`, and passing
nothing means the default. `isProjectName` refuses `default` for the same
reason: a second way to name it would be a second entry for it in every list.

Two workspaces reach a turn, and they answer different questions. The project's
(`<project>/workspace/`) is where work another conversation should find goes,
and it is the `HOME` of every command — so a repository cloned, a package
installed or a `~/.gitconfig` written by one conversation is already there for
the next, and one project is one environment. The chat's own is a folder
*inside* it (`<project>/workspace/chats/<id>/`) and is the working directory of
every command: a turn's scratch files stay the turn's without being hidden from
the user or from the next conversation. What a chat *is* — the log, and what was
attached to it — stays in `chats/`, which the agent is never given a path to.

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
project-scoped path is built through it. `isProjectName` is the same rule read
the other way: a directory that could not have been created as a project is not
listed as one, so a stray `.git` beside them is not a project with no chats in
it.

## Development

- Build/test Linux desktop inside the `flutter-dev` toolbox (host lacks
  cmake/ninja/clang++): `toolbox run --container flutter-dev flutter build linux --debug`.
- UI runs forwarded to host: `toolbox run --container flutter-dev flutter run -d linux --debug`.
- Web: `toolbox run --container flutter-dev flutter run -d web-server --web-port 8087 --web-hostname 127.0.0.1`.
  Nothing runs the app in a browser here, so a web-only regression in the UI is
  caught by reloading the page.
- Voice mode on Linux needs `parecord` on `PATH` (`pulseaudio-utils`); without
  it a session fails to start rather than hearing nothing.
- Package the Linux build:
  `linux/packaging/make-appimage.sh build/linux/x64/release/bundle dist/entoli.AppImage`.
  Needs no toolbox; it downloads `appimagetool` itself.
- Bundled tools (Android's proot and llama.cpp): `ANDROID_NDK_ROOT=$HOME/.android/ndk/<version>
  tool/bundle/build.sh arm64-v8a` then `tool/bundle/stage.sh`. None of it is run
  by the app build; without them an APK has no way to run a Linux and no model
  server. The llama.cpp half needs cmake and ninja, so the `flutter-dev`
  toolbox, and is built for arm64 alone. `$HOME` rather than `~`: a tilde is not
  expanded as an argument to `env` or inside quotes, and the build then fails on
  a literal `~`.
- git is no longer among them. The agent gets it from `apk` inside the Alpine
  rootfs, which is a distribution's job to patch rather than ours — so a device
  with no rootfs installed has no git.
- The NPU is opt-in and wants Qualcomm's SDK: `tool/android-setup.sh` fetches it
  into `tool/bundle/toolchains/` against a pinned SHA-256 and `build.sh` finds it
  there. Only the NPU is gated on it: the build always carries the CPU and the
  Vulkan GPU backend, so a build without the SDK still accelerates most phones,
  and the settings page says the device has no accelerator only when it has
  neither an NPU nor a Vulkan-1.1 GPU — see "What the NPU actually is".
- Codegen: `dart run build_runner build` (freezed + json_serializable).
- Analyze: `flutter analyze`. Tests: `flutter test` — see `test/CLAUDE.md`.
- The repo is not `dart format` clean and is not meant to be; match the file you
  are in rather than reformatting it.

## Dependency note

Freezed 3.x requires `abstract class Foo with _$Foo` (not just `class`).
Build runner capped at `^2.15.1` to stay compatible with freezed 3.2.5's
analyzer constraint. riverpod_generator dropped due to analyzer conflict with
freezed; we use manual Riverpod providers.
