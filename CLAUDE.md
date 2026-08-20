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
  and agents, Resending a message, Attachments
- `lib/ui/sidebar/CLAUDE.md` — The sidebar's list, Pinned chats
- `lib/data/builtin/CLAUDE.md` — The agent loop, Running the commands,
  Approvals, Questions, Sub-agents, Their own transcripts, Carrying one on,
  Web search
- `lib/data/builtin/llm/CLAUDE.md` — Reaching a provider, Errors, and how long
  the UI waits
- `lib/data/local/CLAUDE.md` — Bundled tools, A whole Linux under proot
- `android/CLAUDE.md` — Staying alive off screen, The workspaces in the Files
  app, Being the assistant, The app icon, The debug build's own
- `lib/ui/chat/CLAUDE.md` — When a turn is over, Thinking and tool runs,
  Selecting a reply, and copying it, How a reply is set, Code blocks, The chat
  page
- `lib/data/voice/CLAUDE.md` — Voice mode, What listens and what speaks, The
  Android system engines, Per side, not per session, The Kotlin, Where the
  models live, Hearing and speaking
- `lib/ui/voice/CLAUDE.md` — Reading one message out, The screen
- `lib/ui/workspace/CLAUDE.md` — The workspace explorer
- `lib/ui/share/CLAUDE.md` — Sharing to Entoli
- `lib/ui/CLAUDE.md` — The theme, The keyboard and the caret
- `lib/ui/settings/CLAUDE.md` — Setting overrides, Backing it all up
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
  expanded before the agent sees them.

### On-disk layout

`<dataDir>/chats/<chat-id>/` with `state.json`, `conv.jsonl`, `meta.json`,
`resources/`, `subagents/`, `workspace/`, and `<dataDir>/workspace/` beside
them.
`<dataDir>/projects/<project>/` holds `chats/` and `workspace/` of its own.
`<dataDir>/commands/*.md` and `<dataDir>/agents/*.md` are the user's own prompt
files, beside `settings.json` — which holds the app-level model default, the
title model, the classifier model, `approveMode`, `environment`, `appIcon`,
`appTheme`, and
`llmProviders`.
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

### Projects

A project is a directory holding its own chats and one workspace they share.
The default project is `null`, and it **is** the data directory — so every chat
written before there were projects is already in it, and nothing had to be
moved. `AppConfig`'s path helpers all take `{String? project}` for that reason:
passing nothing means the default project and the layout that was there before.

Two workspaces reach a turn, and they answer different questions. The chat's own
(`chats/<id>/workspace/`) is the working directory of every command and is not
shared with anything. The project's (`<project>/workspace/`) is named in the
system prompt as where work another conversation should find goes. The agent
writes to it by path; it is deliberately not the cwd, because a turn's scratch
files would then be everyone's.

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
- Bundled tools (Android's git and proot): `ANDROID_NDK_ROOT=~/.android/ndk/<version>
  tool/bundle/build.sh arm64-v8a` then `tool/bundle/stage.sh`. Neither is run by
  the app build; without them an APK has no git in it and no way to run a Linux.
  The git half needs `perl` with `FindBin`, which the `flutter-dev` toolbox has
  and this host does not.
- Codegen: `dart run build_runner build` (freezed + json_serializable).
- Analyze: `flutter analyze`. Tests: `flutter test` — see `test/CLAUDE.md`.
- The repo is not `dart format` clean and is not meant to be; match the file you
  are in rather than reformatting it.

## Dependency note

Freezed 3.x requires `abstract class Foo with _$Foo` (not just `class`).
Build runner capped at `^2.15.1` to stay compatible with freezed 3.2.5's
analyzer constraint. riverpod_generator dropped due to analyzer conflict with
freezed; we use manual Riverpod providers.
