# agent-chat

Flutter (Linux/Web/Android) ChatGPT-style UI over a coding agent. Client-side:
it calls the user's own LLM endpoints and runs commands on their machine.

## Architecture

One backend, `MinisweBackend` — mini-swe-agent's loop ported to Dart and running
in this process. No server, no Python, nothing to install. `AgentBackend` stays
as an interface so the UI and repository can be tested against `FakeBackend`.

- `conv.json` is the source of truth. `ChatController` accumulates a turn's
  events into it as they arrive; `ChatRepository` resolves which model runs and
  owns rewinding. Context is re-injected only when a turn is resent — otherwise
  the agent's own session carries it.
- The agent runs **on top of** agent-chat. Commands and agents are agent-chat's,
  expanded before the agent sees them.

### On-disk layout

`<dataDir>/chats/<chat-id>/` with `state.json`, `conv.json`, `meta.json`,
`resources/`, `workspace/`, and `<dataDir>/workspace/` beside them.
`<dataDir>/projects/<project>/` holds `chats/` and `workspace/` of its own.
`<dataDir>/commands/*.md` and `<dataDir>/agents/*.md` are the user's own prompt
files, beside `settings.json` — which holds the app-level model default, the
title model, the classifier model, `approveMode`, `environment`, and
`llmProviders`.
Data dir: `$AGENT_CHAT_CONFIG` if set, else `~/.config/agent-chat` (desktop),
app-private storage (Android). The web build compiles and the UI runs, but
storage is `dart:io`-backed, so a browser has no chats of its own yet.

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

`ChatStore` is addressed by chat id alone, so `LocalChatStore` is what knows
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

### Starting a chat, and naming it

`createChat` writes nothing. The chat is held in `ChatRepository` as its one
draft — with whatever `meta.json` would have held, since writing that would
create the directory a draft does without — and reaches the store the first
time `save` is called, which is the first message. The sidebar lists what the
store holds, so a chat nobody said anything in leaves nothing behind.
`ChatController` invalidates `chatListProvider` after that first save and after
a rename, which are the only two things that change what the sidebar shows;
refreshing it on every message would re-read every chat off disk to draw the
same list.

A chat is created as "New chat" and stays that way unless a **title LLM** is
configured. When one is, `ChatRepository` sends the first message to it through
`AgentBackend.ask` — one call, no tools, no session, not the agent — and
`cleanTitle` cuts the answer down to a title. Nothing waits on it: it is asked
while the turn runs, and it lands through `retitle`, which writes `state.json`
alone because the turn is still adding to `conv.json`. A model that cannot
answer names nothing and the chat keeps the name it has; there is no turn to
report that on.

`ask` is the capability, not the feature: the backend is the only route to a
provider, so a one-shot question belongs on it, while the prompt and the
clean-up are `lib/domain/chat_title.dart` and the repository composes them.

`cleanTitle` exists because the reply names the chat verbatim. Every rule in it
is one of the prompt's instructions being ignored — a quoted title, a `Title:`
prefix, an explanation on the next line, thirty words instead of twenty.

### The agent loop

`MinisweAgent` is mini-swe-agent's control flow in Dart: render the system and
task prompts, ask the model, run the tool calls it made, show it the results,
repeat. It exits when a command's first line is
`COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` and it succeeded — upstream's marker,
kept verbatim so a model that has seen the original recognises it.

Ported rather than embedded because none of the ways of running the real Python
meet "no external setup": `flutter_python_bridge` shells out to the system
`python3` on desktop, Chaquopy is Android-only, Pyodide is web-only, and
litellm — how upstream reaches a provider at all — has native dependencies none
of them can build. The loop is about a hundred lines of actual logic; the model
clients are the large half of the work.

The prompts live in `templates.dart`, adapted from upstream's `mini.yaml` for a
conversation: upstream runs one task and exits, this is asked something else
once the turn is over. A turn's prose streams into the bubble as `TextDelta`,
its commands become tool labels, and the submission's body — everything after
the marker line — is appended as text when a model puts one there.

Two things the prompt has to say explicitly, both learned from watching a real
model fail: that a command only runs when the `bash` tool is called (a model
shown a fenced ```` ```echo MARKER``` ```` will imitate the fence and write the
line as prose, which does nothing), and that it should finish the moment it has
the answer (otherwise it keeps running `pwd`, `date`, `whoami` until the step
limit).

Every tool call gets an answer, including the ones never run — after a submit,
after an abort, for a tool that does not exist. A provider that sees a
`tool_use` with no matching result rejects the *next* turn, so padding them with
"this command was not executed" is what keeps the session usable.

`MinisweSession` holds the conversation as the model sees it, per chat, for as
long as the app runs. `resetSession` seeds a fresh one with a transcript.

#### Reaching a provider

`LlmClient` has two implementations: `OpenAiClient` (`/chat/completions` — and
so also OpenRouter, Groq, Ollama Cloud, ollama, LM Studio, vLLM) and
`AnthropicClient` (`/messages`). Anthropic is not reachable through the first
one: its system prompt is a parameter rather than a message, tool results ride
inside user turns, and consecutive results have to be folded into one turn
because a turn holding N `tool_use` blocks must be answered by exactly one turn
holding all N results.

Thinking is handed back with the `signature` it arrived with. With thinking
enabled, Anthropic rejects a tool-use turn whose thinking was dropped, so
`LlmMessage` carries `reasoningSignature` for no other reason. Enabling
thinking also pins the temperature at 1, so the two are never sent together.

Providers are configured in `settings.json` under `llmProviders` — id, API
shape, base URL, key, and an optional model list — and `llmProviderPresets`
fills in the endpoints worth naming so that adding one is a key rather than a
URL nobody remembers. A key can be left out and named as `apiKeyEnv` instead,
which is how one already exported stays out of the file. `LlmRegistry` builds a
client per provider and rebuilds it when the URL or key changes; a provider that
lists no models is asked, and one that cannot answer contributes nothing rather
than failing the whole list.

#### Errors, and how long the UI waits

Failures are reported as they happen: a rejected key or a bad request reaches
`ErrorEvent` on the first attempt, and a retryable one (429, 5xx, a connection
that never opened) emits `RetryEvent` the instant it fails. Four attempts with
1s/2s/4s backoff means a persistent rate limit is reported after ~7s.

Because nothing is hidden, silence only ever means work, and the UI never
gives up on a turn on its own — the user cancels. A `RetryEvent` is
turn-scoped view state, never a message part, so it is not persisted.

#### Running the commands

`Shell` is the only platform-varying part of the app — `LocalShell` on desktop
and Android, `UnavailableShell` in a browser — which is why
`lib/core/platform/backend.dart` holds the app's single conditional import
(`io/shell.dart` or `web/shell.dart`) and is otherwise plain wiring.

`Shell.canRunCommands` is what a browser actually changes, and it is not one
failing command — it is the whole loop. Submitting is itself a command, so with
no shell a turn could never finish: the agent would nudge the model three times
and end on a red error. False therefore drops `bashTool` from the request, uses
a system prompt with no submission protocol in it, and treats a reply with no
tool call as the finished answer rather than a format error.

`LocalShell` prepends `exec 2>&1` to the script rather than merging two Dart
streams — a compiler's errors interleaved with its progress is the whole value
of reading them, and separate pipes arrive in whatever order they flush. It
spawns under `setsid` where that exists so a timeout can kill the process
group: a timed-out `npm install` that only loses its shell keeps downloading.
Whether `setsid` is there is learned by trying it, not by probing first.

#### Approvals

`approveMode` (`meta.json` over `settings.json`) is resolved once in
`ChatRepository` and arrives with the prompt, so it is a `MinisweAgent`
parameter beside `approve` rather than part of `MinisweOptions`, which holds
only what is genuinely per-agent. Three modes: `ask` (every command waits for
the banner), `auto` (a classifier model decides allow/ask/deny per command),
`never` (run everything). An older file's `approveCommands` bool migrates:
`true` → `ask`, `false` → `never`.

In `auto` mode, a `PermissionClassifier` (the `LlmClassifier` impl, or
`NoClassifier` when no classifier model is configured) is asked before each
`bash` and `webfetch` call. `allow` runs silently, `deny` refuses with a
message, `ask` escalates to the same banner `ask` mode uses. A circuit
breaker pauses auto mode after 3 consecutive or 20 total escalations in one
turn, falling back to `ask` for the rest — emitted as an `InfoEvent` so the
UI can say "auto mode paused." `NoClassifier` always asks, which is why the
default mode is `ask` and `auto` is disabled in the settings UI until a
classifier model is picked. `never` is labeled "(DANGEROUS)" in the dropdown.

The `ApprovalRequestEvent` is emitted *before* the agent waits on it, because
the banner is where the answer comes from. The completer is therefore created
when the event is forwarded, not when it is awaited, and an answer completes it
in place rather than removing it — a user who clicks faster than the loop asks
would otherwise leave it waiting on a completer nobody holds. A turn that ends
with one outstanding denies it.

#### Questions

`ask_user` is the one tool that runs nothing: the model puts questions to the
user and the turn waits. Offered with or without a shell — a browser cannot
run a command, but it can still ask — which is why `_tools` exists and
`unknownTool` is told what was on offer rather than assuming `bash`.

The call and its answers are an ordinary call/result pair, so `conv.json` keeps
them with no new part type in it, a rewind carries them like anything else, and
the chat draws an answered question back out of what was persisted. `AskLabel`
is that: the question on a label, the answers behind the drawer, parsed once and
kept — every visible message is rebuilt on every streamed delta. What it draws is
decided by what parsed, not by the name that got it there: a call named
`ask_user` with nothing askable in it falls back to `ToolLabel`, which shows the
rejection the model was sent.

Answering is `_answer`, one tool message per call — the invariant that keeps the
next turn from being rejected. `_answerRun` is that plus the wording a command's
outcome gets, which is every call but an `ask_user`.

`lib/domain/ask.dart` holds both directions of the format, `askAnswers` beside
`askAnswersFrom`, so the round trip is one file. `askQuestionsFrom` is
deliberately liberal: the arguments are the model's writing, not ours, so it may
batch under `questions` or write one question out at the top level, and it
reaches for whichever word its prompt left in its head — `angles`, `choices`,
`query` for a value. A question with no options is the one thing rejected,
because the panel answers by clicking and there would be nothing to click. Every
question comes back to the model whether or not it was answered: one that asked
three and got two needs to know which one it is still missing.

`QuestionPanel` takes the composer's place while a request is up — including its
stop button, which is why `Skip` is on the panel: it answers with nothing so the
turn can carry on, and it is the only way out. The rest mirrors approvals
exactly: turn-scoped view state, `_clearQuestions` beside `_clearApprovals` so an
abandoned turn answers its own questions, the completer created when the event is
forwarded rather than when it is awaited.

#### Sub-agents (the `task` tool)

`task` spawns a sub-agent with its own session under the named `@agent`'s
prompt, runs it to completion headless, and returns its final text as the tool
result. The sub-agent shares the parent's model, shell, and workspace, but
sees nothing of the parent's conversation — the prompt is its whole task. It
has no `task` (sub-agents do not fan out), no `ask_user` (nobody answers), and
runs under `ApproveMode.never`: a fan-out of 75 voters is not usable if each
one stops on a banner.

`SubAgentRunner` holds the running agents so `cancel` reaches them — a turn
aborted while sub-agents are running kills every one, not just the parent's
loop. The parent's `_executeTasks` runs the calls concurrently, capped by
`MinisweOptions.maxConcurrentSubAgents` (8 by default — deep-research can fan
out to 75, and 8 concurrent keeps provider rate limits in view). Events
stream out as each sub-agent resolves, but the session messages are answered
in the calls' original order, so the tool results pair up with the calls.

Non-`task` calls in the same message run first, in order, so a command before
the fan-out is done before it starts and one after waits for it. The
alternative — interleaving a sub-agent with a command it might depend on —
would race the two.

`SubAgentStartEvent` / `SubAgentEndEvent` are turn-scoped view state (like
approvals and questions), so `conv.json` keeps the call/result pair and
nothing more; a reloaded chat draws a `TaskLabel` from the call's arguments
alone. `SubAgentStrip` shows the running ones as chips above the composer.

#### Web search (the `websearch` / `webfetch` tools)

`websearch` queries DuckDuckGo Lite — no API key — and returns titles, URLs,
and snippets. `webfetch` is a plain GET with markup stripped to text. Both
are read-only, so they run without an approval banner in every mode — the
classifier gates `webfetch` (it reaches a URL the model chose) but not
`websearch` (it reads a search engine's answer to a query).

`WebSearch` is the interface, like `Shell` for commands: `DuckDuckGoSearch`
on desktop and Android, `UnavailableWebSearch` on the web platform (CORS
blocks cross-origin requests from a browser). `Shell.canRunCommands` gates
`bash`; `WebSearch.available` gates `websearch`/`webfetch` the same way —
offered where there is something to reach, dropped where there is not. The
search page is HTML, not JSON, so results are parsed out of the table it
renders. Both return a `ShellResult`, so the agent words a search's outcome
the same way it words a command's — the model reads one shape, whatever ran.

#### Live test

`test/live/miniswe_live.dart` drives a real provider through the production
path. It deliberately does **not** call
`TestWidgetsFlutterBinding.ensureInitialized()`: that installs an
`HttpOverrides` answering every request with a 400, which is the whole of what a
live test is for. That rules out `rootBundle`, so it copies `assets/prompts/`
off disk instead of using `BundledPrompts`. Not a `_test.dart` file, so
`flutter test` skips it.

### Thinking and tool runs

A turn is not just a reply: the model thinks, runs tools, thinks again. Each of
those is a part of the assistant message and the chat draws it as a frameless
label above the bubble, in the order it happened, with the detail behind a
bottom drawer. The bubble holds only what the model said.

`durationMs` is what the label reads ("Thought for 12 seconds") and is null
while the block is still being written — which is also how the UI knows to say
"Thinking…", and how the controller finds the block a delta or a close belongs
to. It searches for that open block rather than assuming it is the last part: a
provider that interleaves parts can start a tool between a block's deltas and
the event closing it, and assuming the last part wrote the thinking twice. A
block that was never timed — an older conversation, an aborted turn — is still
worth opening, so it reads "View thinking". `ReasoningEnd` carries the whole
text as well as the duration, so a provider that streams no deltas still fills
the block.

`ReasoningPart` is not a `TextPart`, so `plainText` leaves it out: a rewound
session is seeded with what was said, never with what was thought.

A tool call and the result answering it are one label. The parts stay separate
in `conv.json` (they arrive at different times) and the UI pairs them by
`callID`; a result whose call is gone draws its own.

### Commands and agents

`PromptLibrary` is the whole of what the composer's `/` and `@` menus offer,
built once at startup from two `PromptSource`s in precedence order: the presets
packaged under `assets/prompts/{commands,agents}/`, then
`$AGENT_CHAT_CONFIG/{commands,agents}/`. A file the user wrote replaces the
preset it shares a name with. Entries come back sorted by name, so the menu does
not reorder when a source does. Built once because reading assets is async and
nothing downstream should wait on it; a file added while the app runs therefore
does not appear until a restart, though nothing would break if it did — the
agent looks documents up per turn.

A prompt file is YAML frontmatter, then the template a command expands to or the
system prompt an agent runs under. `PromptDocument` reads only the top-level
scalars — `description` is all the menu needs.

The syntax is parsed in `MinisweBackend` (`_command` / `_mention`), not in the
repository or the UI: `conv.json` stores the message as typed, so a regenerated
turn re-parses to the same thing. `activeCompletionToken` in the composer has to
agree with those two patterns — anything the menu offers has to dispatch.

`/name args` expands to the command's body with `$ARGUMENTS` substituted (or
appended); a name the library does not know is left alone, because it is more
likely a path. `@name` stacks that agent's prompt under the system message.

`completions` is therefore **not** on `AgentBackend`: `completionsProvider`
reads the library directly and is synchronous.

### Resending a message

Edit and regenerate discard the turn and everything after it, then re-run it.
The live session still holds the discarded exchange, so `resetSession` drops it
and seeds a fresh one with `transcriptOf` the kept messages. This is the one
place where the "conv.json is the source of truth, re-inject context" rule is
actually exercised. The transcript names the files the kept messages carried
rather than resending them: only the turn being replayed carries its own back.

### Attachments

The `+` button offers Image and File. Both open the same chooser and differ only
in its filter, so they share one path: `AttachmentPicker` (a domain interface,
`file_selector` behind it, faked in tests) hands back `Attachment`s of filename,
mime type and bytes.

Bytes are saved under the chat's `resources/` and the message keeps a `FilePart`
naming the resource. That is what makes an edit or a regenerate work: the parts
are in `conv.json`, so a resend reads the bytes back off disk rather than
needing the composer to still hold them. `saveAttachments` leaves one that
already has a resource where it is, so replaying a turn does not copy its bytes
again.

The store's resource I/O is async where the rest of it is sync: a JSON file is
small enough to write on the UI thread, an attachment is not. A widget test's
clock is fake and never advances real I/O, which is what `pumpUntil` in
`test/harness.dart` is for.

### Setting overrides

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

The settings page is three sections plus deleting everything: **New chats**
(default model, title model), **Agent** (command approval mode, classifier
model, providers), **Environment**.

### Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` and
`OptionalModelPicker` (each a field over the model list, sharing the loading and
failure states every page would otherwise spell out) over
`ProviderModelSelector` (which owns every rule about the pair, and is tested
directly in `provider_model_selector_test.dart` rather than through both pages),
the
`Default`-plus-reset pairing, `LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs, and `AttachmentChip` /
`AttachmentStrip`. Tests share `test/harness.dart` (`TestApp`, `tempConfig`,
`pumpUntil`, `seedChat` for a chat that is actually listed, the dropdown
finders) and `test/fakes.dart` (`FakeBackend`, whose `scriptedEvents` and `hold`
drive a turn and whose `scriptedTitle` names a chat, plus `FakeAttachmentPicker`
and `testLibrary`).

Streamed deltas are coalesced into one state update per frame: per-token updates
made the reply's text quadratic and rebuilt every visible bubble thousands of
times per turn. One buffer carries both kinds of delta, so switching between
thinking and reply flushes what it held — otherwise the two would fold into each
other's part.

`activity_label.dart` owns the labels and the drawer behind them; the bubble
walks the parts and decides which of the two each one is.

`Composer` opens a menu above the field when the caret sits in a `/` or `@`
token, over a library that is already loaded — so it takes no chat id, has no
loading state, and starts nothing. Enter, Tab and the arrows are bound only
while the menu has a match — the rest of the time they have to keep doing what
they do in a text box. The `+` button left of the field is a second way in: for
a command or an agent it types the trigger character rather than opening its own
list, so both routes share one code path; for a file it opens the chooser.

## Development

- Build/test Linux desktop inside the `flutter-dev` toolbox (host lacks
  cmake/ninja/clang++): `toolbox run --container flutter-dev flutter build linux --debug`.
- UI runs forwarded to host: `toolbox run --container flutter-dev flutter run -d linux --debug`.
- Codegen: `dart run build_runner build` (freezed + json_serializable).
- Analyze: `flutter analyze`. Tests: `flutter test`.

## Dependency note

Freezed 3.x requires `abstract class Foo with _$Foo` (not just `class`).
Build runner capped at `^2.15.1` to stay compatible with freezed 3.2.5's
analyzer constraint. riverpod_generator dropped due to analyzer conflict with
freezed; we use manual Riverpod providers.
