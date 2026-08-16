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

## Architecture

One backend, `MinisweBackend` — mini-swe-agent's loop ported to Dart and running
in this process. No server, no Python, nothing to install. `AgentBackend` stays
as an interface so the UI and repository can be tested against `FakeBackend`.

- `conv.jsonl` is the source of truth, and it is a log rather than a document.
  `ChatController` appends a turn's events to it as they arrive;
  `ChatRepository` resolves which model runs and owns rewinding. Context is
  re-injected only when a turn is resent — otherwise the agent's own session
  carries it.
- The agent runs **on top of** Entoli. Commands and agents are Entoli's,
  expanded before the agent sees them.

### On-disk layout

`<dataDir>/chats/<chat-id>/` with `state.json`, `conv.jsonl`, `meta.json`,
`resources/`, `workspace/`, and `<dataDir>/workspace/` beside them.
`<dataDir>/projects/<project>/` holds `chats/` and `workspace/` of its own.
`<dataDir>/commands/*.md` and `<dataDir>/agents/*.md` are the user's own prompt
files, beside `settings.json` — which holds the app-level model default, the
title model, the classifier model, `approveMode`, `environment`, `appIcon`, and
`llmProviders`.
Data dir: `$AGENT_CHAT_CONFIG` if set, else `~/.config/agent-chat` (desktop),
app-private storage (Android), and `/agent-chat` in a browser — where it is a
name in IndexedDB rather than a path, and load-bearing all the same.

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

### The conversation log

`conv.jsonl` is a log of `ChatRecord`s, one per line, appended as a turn happens
and never rewritten. It was a JSON document, and a document has to be written
whole to stay parseable — so it could only be written once a turn was over, and
a turn killed halfway left nothing at all. A line is complete the moment it is
written, so the only thing a kill can now cost is whatever had not been appended
yet. That is what makes an interrupted turn something to offer to continue
rather than something to apologise for.

Five records. `message` opens one — before it holds anything, which is what the
empty assistant message at the head of a turn is. `part` is one part of it, at
an index. `append` is more text on the end of the part at an index. `turnEnd`
closes the turn and says why: `done`, `aborted`, or `error`. `rewind` forgets a
message and everything after it.

Nothing is mutable, so a part that changed is **superseded**: the same index
written again wins, and `replay` applies records in order, so the last one
stands. That is what lets a thinking block be closed after a tool call has
landed behind it — `_appendChanged` diffs the reply's parts against what it last
wrote rather than counting them, because the part that changed is not always the
last one.

`append` exists because superseding is the wrong shape for the common case.
Rewriting a growing reply whole on every checkpoint costs its whole length once
per second it streams for, so a local model answering slowly would write its
reply a hundred times over and decode all hundred copies on every open. Only
text grows a piece at a time, so `textGrownFrom` decides — a part that grew and
changed nothing else is written as the piece it grew by, and anything else is
written whole.

`turnEnd` matters most when it is **missing**: a log whose last message has no
`turnEnd` was being written when the process died, and that absence is the only
thing that can tell a reload the difference between a killed turn and a finished
one. `aborted` is kept distinct from `error` for the same reason — a turn
someone chose to stop is not one to offer to resume. See "Carrying on an
interrupted turn" for what reads all this.

Rewinding is a record rather than a truncation because shortening a log means
rewriting it, which is the one thing the format exists to avoid.

`replay` is deliberately liberal: a part naming a message that is not there, or
an index past the end of one, is skipped. The reader's job is to salvage a file
written by a process that could be killed between any two lines, which is also
why `decodeLog` stops at the first line that will not parse rather than failing
— appends are ordered, so a broken line is the one the kill landed in and
everything before it is whole. Both live in `chat_log.dart` with the record
types, so the one file that describes the format is the one that reads and
writes it.

There is deliberately no whole-log write. `ChatStore` offers `append` and
nothing else for a conversation, because a whole-log write is the truncation the
format exists to avoid — a chat assembled in memory is
`append(id, recordsOf(messages))`, which is what the tests seed with.

Two writers would interleave lines, so the controller's appends go through one
queue. Queued work reads the state when it runs rather than capturing it, so
calls that pile up behind a slow write collapse into one no-op each. Not the
serialising queue rejected above: that one was in the store and made a read wait
on a write, this one is per-controller and write-only. It has a trap of its own
— the chain starts null rather than at a completed future, because a
`Future.value()` built on a widget test's fake clock only completes when the
tree is pumped, and the first append is awaited from inside `runAsync`, where
nothing can pump.
`ChatController` writes a part the moment it lands, from `_appendPart` /
`_endReasoning` / `_appendError` rather than from the event arms that call them,
so a new kind of event cannot forget to log what it added. Text is the exception
and goes on a one-second timer, since it grows with no event to hang a write
off. That timer is one-shot and re-armed by the
next delta, not periodic: a timer that rearms itself forever is a widget test
that never settles.

One thing the format still wants: nothing compacts. A chat regenerated ten times
carries eleven copies of that turn's records and pays for them on every open, so
`load` will want to rewrite the log once the dead records outweigh the live ones.

#### The projection

`replay` reads the log for the UI; `projectionOf` reads it for a provider, and
the two are what the log exists to make possible. A domain `Message` is a whole
turn and a turn is several provider responses — think, call a tool, look at the
result, think again — so it splits one assistant message back into one
`LlmMessage` per response, each followed by the `tool` messages answering its
calls. Handing a response's thinking back with a later response's tool calls is
rejected, so the split has to be right. Named `projectionOf` rather than
`project`, which everywhere else here is the directory a chat lives in.

That is what `responseId` is for. `MinisweAgent` names each step before it runs
and emits `ResponseStart`; every part the controller writes while it is set
carries it, so the grouping is read out of the log rather than guessed from the
order parts happen to be in. A part naming no response — a result, an error —
belongs to the response before it.

`ReasoningPart.signature` is Anthropic's and exists only for it: with thinking
enabled it rejects a tool-use turn whose thinking comes back unsigned. Nothing
else reads the field, so it goes when `AnthropicClient` stops needing one. It is
`AnthropicClient` that decides when: the signature arrives while the thinking
block is still open, and it is yielded there as `LlmReasoningSignature` rather
than waiting for the completion, so the block is closed already holding it
instead of being written to the log a second time.

A result is worded the way the agent worded it when it ran — `observation(...)`,
or the answers themselves for an `ask_user` — so a projected conversation is the
one the model already answered rather than a paraphrase of it. A call whose
result never landed is answered anyway, since a provider that sees a tool call
with no result rejects the next turn — worded by what was called, which is the
next section. Attachments are named, not resent: the bytes are on disk and
reading them back would make this asynchronous.

Three things reach for it. `resetSession` on a rewind, which is what it replaced
— the old path wrote the kept messages out as prose and told the model "earlier
in this conversation", losing the thinking, the calls and the results.
`sendPrompt`, which fills a session that is empty: sessions live in memory for as
long as the app does, so a chat opened after a restart has none, and the model
would have been answering the next message having seen nothing of the chat. And
`resumeTurn`, which rebuilds one whether or not it is empty.

That is why `history` is a `sendPrompt` parameter rather than a call of its own.
A separate "give the backend the conversation" method is one a caller can
forget, and forgetting it is silent — the model answers fluently from nothing
rather than failing. Riding with the prompt, there is no order to get wrong. It
comes from the controller rather than being read back off the store, since the
turn's own records are still on their way there.

What the projection restores is not free. `seed` collapsed any history into two
messages of prose; this puts back every response, every thinking block with its
signature, and every result verbatim, and the whole session is resent on every
model call of the turn. That is parity — a live session that actually ran those
steps holds exactly those messages — but it is what makes compaction, above, the
thing that bounds a long chat.

#### Carrying on an interrupted turn

The design is deliberately dumb. Nothing resumes on its own, nothing is told to
the model about what the interruption may have done, and nothing is written to
tidy up a turn the user walked away from. Three routes out of an interrupted
turn, all the user's: press Continue, press Regenerate, or say something else
and carry on with the incomplete reply still in the conversation.

`endsUnfinished` is the whole of the classifier: the log's last message, if it is
a reply, and the last record naming it. `TurnEnd.resumable` decides — missing
means the process was killed and `error` means the turn gave up, and nobody chose
either; `done` finished and `aborted` is the one case where the user has already
said to stop. It is on the enum because two places ask, the log's reader and the
controller closing a turn, and they have to agree or the offer flickers on the
next reload. `chatFrom` is the classifier and `replay` together, and it is what
both stores load through.

Only the **last** reply is asked about, and that is the rule rather than a
shortcut. Every turn is marked, so a reply in the middle of a conversation can be
left open — kill a turn, then type something new instead of carrying on, and that
one stays open for good. It is still not resumable: resuming appends to a
message, so continuing one from the middle would put new work before turns that
already happened and that the model has since built on. Nothing reads it either,
so nothing closes it; a tidy-up record would be written for no reader.

One assumption is worth naming because it is invisible: an open log means nothing
is running only because a turn cannot outlive the process running it. The
foreground service of stage 5 breaks that, and a UI attaching to a chat whose
turn is still running in the service would read an open log and offer Continue
over the top of it.

`Chat.unfinished` carries the answer out of the store as a bool — an id would
only ever be `messages.last.id`, an invariant nothing could enforce. The chat page
draws a `ResumeBar` above the composer from it, with the turn's age on it:
continuing one from ten minutes ago is a different proposition from continuing
one from a week ago, and only the reader can tell which this is. `_finishTurn`
sets the flag to what a reload would now say, so a turn that gives up is offered
straight away rather than only after the chat is opened again.

Continuing **adds to the same reply** rather than starting another. There is one
assistant message per turn and the interrupted turn is not over, so
`ChatController.resume` seeds `_logged` with the parts the log already holds and a
checkpoint writes only what this turn puts on the end. The message is then closed
by a second `turnEnd`, which is why the classifier reads the last record naming a
message rather than the first — and why `_outcome` is turn-scoped rather than
read off the reply's parts, which is what it used to be. One message was one turn
until this landed.

`MinisweAgent.resume` is `run` without the task, over a session rebuilt from
`projectionOf` the conversation **whether or not one is already held**. Not
because a held session would double anything — it holds those messages exactly
once — but so that carrying on in the same process and carrying on after a
restart put the same thing in front of the model. A checkpoint that failed is
swallowed on purpose, so a live session can hold more than the log does, and it
is the log the user is reading.

`AgentBackend.resumeTurn` is a method of its own rather than a flag on
`sendPrompt`, because there is no prompt: no text, no attachments, no `/command`
or `@agent` to expand. `@agent` mentions are recovered by re-parsing the last user
message, the same way a resend re-parses rather than storing what it resolved to.
What the two share is `TurnSettings`, resolved once by `ChatRepository`.

The projection's answer to a call whose result never landed is the other half of
this, and it is **one wording for every tool**. Which tool it was is in the call
the model can already see, and refining "it may not have run" per tool is
second-guessing an interruption nothing witnessed — that was tried and removed.
It splits only where `_resultText` already splits, since an `ask_user` is answered
in prose either way. Answered rather than dropped, tempting as dropping a
re-runnable read is: the call is in `conv.jsonl` and on the screen, so a model
with no memory of making it is a model that disagrees with the conversation the
user is reading, and the thinking and any command that did land in the same
response would go with it.

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
alone because the turn is still adding to `conv.jsonl`. A model that cannot
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
repeat. It exits when the model replies with no tool calls — the reply text is
the answer — or when it hits the step limit. This is the native API contract
models are trained on (text-only message = finished answer, tool calls =
continue), which works reliably across model sizes. The codebase previously
used mini-swe-agent's `COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` marker as the
termination signal, but that protocol was a forcing function for weak models on
SWE-bench and failed on exactly the small models this app targets: they called
the marker without writing answer text, leaving the sub-agent runner with an
empty buffer.

Ported rather than embedded because none of the ways of running the real Python
meet "no external setup": `flutter_python_bridge` shells out to the system
`python3` on desktop, Chaquopy is Android-only, Pyodide is web-only, and
litellm — how upstream reaches a provider at all — has native dependencies none
of them can build. The loop is about a hundred lines of actual logic; the model
clients are the large half of the work.

The prompts live in `templates.dart`, adapted from upstream's `mini.yaml` for a
conversation: upstream runs one task and exits, this is asked something else
once the turn is over. A turn's prose streams into the bubble as `TextDelta`,
its commands become tool labels, and a no-tool-call reply ends the turn.

One thing the prompt has to say explicitly, learned from watching a real model
fail: that a command only runs when the `bash` tool is called (a model shown a
fenced ```` ```echo foo``` ```` will imitate the fence and write the line as
prose, which does nothing). Finishing is native — the model just replies with
text and no tool call — so no marker instruction is needed.

Every tool call gets an answer, including the ones never run — after an abort,
for a tool that does not exist. A provider that sees a
`tool_use` with no matching result rejects the *next* turn, so padding them with
"this command was not executed" is what keeps the session usable.

`MinisweSession` holds the conversation as the model sees it, per chat, for as
long as the app runs — which is the whole of its lifetime, so `resetSession` and
an empty one at the head of a turn are filled from the log through
`projectionOf`. See "The projection".

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
`LlmMessage` carries `reasoningSignature` and `ReasoningPart` carries
`signature` for no other reason — see "The projection". Enabling thinking also
pins the temperature at 1, so the two are never sent together.

Providers are configured in `settings.json` under `llmProviders` — id, API
shape, base URL, key, and an optional model list — and `llmProviderPresets`
fills in the endpoints worth naming so that adding one is a key rather than a
URL nobody remembers. A key can be left out and named as `apiKeyEnv` instead,
which is how one already exported stays out of the file. `LlmRegistry` builds a
client per provider and rebuilds it when the URL or key changes; a provider that
lists no models is asked, and one that cannot answer contributes nothing rather
than failing the whole list.

A `RateLimitGate` is built per turn in `MinisweBackend.sendPrompt` and shared by
the parent `MinisweAgent` and every sub-agent it spawns: it bounds in-flight
`LlmClient.stream` calls to `MinisweOptions.maxConcurrentLlmRequests` (4
default) through a `GatedLlmClient` wrapper, and coordinates 429 backoff so a
75-vote fan-out doesn't each-retry-into the same rate limit. When any one
request gets a 429, the gate sets a shared cooldown that every other in-flight
or queued request honours; backoff grows exponentially across successive 429
episodes (1s → 2s → 4s → … → 60s cap) and resets on any successful request. The
gate is distinct from `maxConcurrentSubAgents` (8), which bounds long-lived
agent parallelism — one sub-agent makes up to `stepLimit` calls. Null for agents
built against a raw client (tests), where the per-agent retry path governs.

#### Errors, and how long the UI waits

Failures are reported as they happen: a rejected key or a bad request reaches
`ErrorEvent` on the first attempt, and a retryable one (429, 5xx, a connection
that never opened) emits `RetryEvent` the instant it fails. Four attempts with
1s/2s/4s backoff means a persistent 5xx or connection error is reported after
~7s. A 429 takes a different path: a `RateLimitGate` shared across the parent
and every sub-agent coordinates backoff so a fan-out pauses as one rather than
each-retry-into the same limit (see "Reaching a provider"). 429 retries
continue for `MinisweOptions.rateLimitRetryBudget` (5 min default) with
exponential backoff capped at 60s; other retryables keep the per-agent
`maxAttempts` budget. Where no gate is present (tests against a raw
`FakeLlmClient`), 429s fall back to the per-agent path.

Because nothing is hidden, silence only ever means work, and the UI never
gives up on a turn on its own — the user cancels. A `RetryEvent` is
turn-scoped view state, never a message part, so it is not persisted.

#### Running the commands

What the app is given by the platform it runs on — a shell or none, the network
or CORS, a directory on a disk or a database in a page — is resolved in
`lib/core/platform/platform.dart`, which holds the app's single conditional
import (`io/platform.dart` or `web/platform.dart`) and is otherwise plain
wiring: `LocalShell`, `DuckDuckGoSearch` and `fileSystemIo` on desktop and
Android; `UnavailableShell`, `UnavailableWebSearch` and `fileSystemWeb` in a
browser. One import site is the point: an implementation a platform cannot use
is not reachable from its program, so nothing further down has to test for it.

The chat store and the prompt sources used to be in that list and are not any
more — one filesystem means one of each, built in `platform.dart` itself. What
is left varying is the shell, the network, which `FileSystem`, where its root
is, whether the process has an environment, and `platformPersist`: on the web
that is `navigator.storage.persist()`, without which IndexedDB is evictable and
a chat can be gone on the next visit because something else wanted the space. A
browser that refuses leaves the app working, just evictable again. Everywhere
else it is a no-op, because a directory on a disk is already as durable as the
app is.

`MinisweBackend.webSearch` is required rather than defaulted for that reason —
a default of `DuckDuckGoSearch()` puts its HTML parser in the web bundle
(~280 KB) where CORS means it can never be called.

`Shell.canRunCommands` is what a browser actually changes, and it is not one
failing command — it is the whole loop. With no shell there is nothing to run,
so `bashTool` is dropped from the request and a system prompt with no tool
instructions is used; the turn ends when the model replies with text and no
tool call, the same termination signal the shell path uses.

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

The call and its answers are an ordinary call/result pair, so `conv.jsonl` keeps
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
approvals and questions), so `conv.jsonl` keeps the call/result pair and
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

### When a turn is over

`_finishTurn` drains the append queue and writes the `turnEnd` record before it
clears `isRunning`. Returning earlier would report a finished turn whose last
records are still in flight, and closing the app in that window would lose them
— and would leave a log that reads as killed when it was not. The window is
milliseconds on a disk and longer on IndexedDB. A write that fails still has to
clear the flag, or the composer stays disabled with nothing running.

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
in `conv.jsonl` (they arrive at different times) and the UI pairs them by
`callID`; a result whose call is gone draws its own.

What can be done to a message — Edit, Regenerate — is a row of icons under it
rather than a menu, uncovered by hovering the message or, where there is no
pointer to hover with, by touching it. The row keeps its height whether or not
anything is in it, so the conversation does not shift under the pointer the
moment the icons appear. The reveal is a `Listener` rather than a
`GestureDetector`: a raw pointer listener sidesteps the gesture arena, so one
touch both places the caret in the bubble's `SelectableText` and shows the
actions. It writes a `ValueNotifier` rather than calling `setState`, so
uncovering the icons does not rebuild the message's labels behind them.

### The chat page

One app bar, whichever layout it is drawn in. Narrow, the sidebar is `ChatPage`'s
own drawer rather than a shell's — two bars stacked was the app's name over the
chat's, saying nothing twice. What it shows follows the conversation: the mark
and "Entoli" while the list is at its top, the chat's title and project once it
is not. A chat too short to scroll is always at the top, so it keeps the mark.

A chat opens at its latest message. `_openAtBottom` jumps and then jumps again
until the extent stops moving: a builder lays out only what shows, so the extent
the first frame reports is an estimate and one jump lands short of the end. Not
`reverse: true`, which would land at the end exactly and for free — in a
reversed viewport the offsets of older messages shift as the newest one grows,
so a reader scrolled up during a turn would watch the text move.

A turn follows itself only while the reader is already within `_slack` of the
end. Outside it the list is left alone — the offsets of earlier messages do not
move as the last one grows, so reading back through a turn is undisturbed — and
a button appears to go back down. The same slack decides both, so the button
turns up exactly when the view stops keeping up. Both edges are
`ValueNotifier`s, since a `setState` mid-drag would rebuild every visible bubble
to swap a title or a button.

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
repository or the UI: `conv.jsonl` stores the message as typed, so a regenerated
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
and puts back `projectionOf` the kept messages — thinking, calls and results and
all. This is where the "conv.jsonl is the source of truth, re-inject context"
rule is exercised, and the projection is what makes it true rather than
approximate. Only the turn being replayed carries its own attachments back; the
kept messages name theirs.

### Attachments

The `+` button offers Image and File. Both open the same chooser and differ only
in its filter, so they share one path: `AttachmentPicker` (a domain interface,
`file_selector` behind it, faked in tests) hands back `Attachment`s of filename,
mime type and bytes.

Bytes are saved under the chat's `resources/` and the message keeps a `FilePart`
naming the resource. That is what makes an edit or a regenerate work: the parts
are in `conv.jsonl`, so a resend reads the bytes back off disk rather than
needing the composer to still hold them. `saveAttachments` leaves one that
already has a resource where it is, so replaying a turn does not copy its bytes
again.

The store's resource I/O is async where the rest of it is sync: a JSON file is
small enough to write on the UI thread, an attachment is not.

### The app icon

Two icons, `AppIcon.prompt` (the default) and `AppIcon.cookie`. Each exists
several times over, because each platform wants its own form and they are
checked in rather than built: `assets/icons/*.svg` is what the app draws,
`drawable/ic_<name>_{foreground,monochrome}` over the shared
`ic_icon_background` are the Android adaptive layers named by
`mipmap-anydpi-v26/ic_<name>.xml`, and `web/icons/` is the PWA set. Android
reads no SVG, so its copies are the same path data as a vector drawable, and
editing one means editing all of them — there is no generator.

`minSdk` is pinned to 26 rather than following `flutter.minSdkVersion`, which
is 24. Adaptive icons start at 26; below it every icon needs a full set of
rasters at five densities as well, which was ten files existing only for
Android 7.x. Pinning it is also what let the pre-Lollipop
`drawable/launch_background.xml` go — the `-v21` one it shadowed reads the
theme background instead of hardcoding white, so the splash follows dark mode.

The monochrome layer is not decoration: a themed icon is the silhouette tinted
from the wallpaper, so an icon whose meaning lives in its colour has none there.
The background is one file for both icons rather than one each, since both sit
on the same flat indigo.

`<application android:icon>` points at `@mipmap/ic_prompt`, the default icon's
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
`android:icon` (`@mipmap/ic_prompt`); each non-default icon is an
`activity-alias` targeting `MainActivity`, disabled by default. Exactly one
entry is enabled at a time, or the app appears on the home screen twice — so
`MainActivity.kt` treats the default as one entry among the aliases, enabling
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
come from different strings. The manifest's `.CookieIcon` is expanded against
the **namespace**, so the class name is derived from `MainActivity`'s own
package, while the package half has to be `packageName` — the id the app is
installed under, which the debug `applicationIdSuffix` (`.debug`, what lets a
debug and a release build sit side by side) makes a different string. Naming the
package half with the namespace makes `setComponentEnabledSetting` throw, and
the Dart side swallows that, so the first version of this silently did nothing
in every debug build.

Not behind a conditional import the way `Shell` is: a `MethodChannel` compiles
everywhere and a platform with nothing answering it throws, which is the same
no-op `available` being false gives. So the app still has exactly one
conditional import.

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

The settings page is four sections plus deleting everything: **New chats**
(default model, title model), **Appearance** (app icon), **Agent** (command
approval mode, classifier model, providers), **Environment**.

### Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` and
`OptionalModelPicker` (each a field over the model list, sharing the loading and
failure states every page would otherwise spell out) over
`ProviderModelSelector` (which owns every rule about the pair), the
`Default`-plus-reset pairing, `LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs, and `AttachmentChip` / `AttachmentStrip`.

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

It never asks for the field's focus, and that is the whole rule. On Android focus
is the keyboard, so a composer that reaches for it is a keyboard rising over a
conversation nobody was typing in — which is what attaching a file did, and what
the `+` menu's own entries did. Neither has anything to type at: the file is
already on the strip, and the menu the trigger character opens is tapped. The
field has no `FocusNode` of its own any more, since nothing was left to point one
at.

What went with it is a second mechanism that existed only to undo the first: the
`+` menu hands focus back to whatever held it when it closes, so a field still
holding it brought the keyboard up again, and the composer watched the view
insets for the keyboard Android closes without telling Flutter so it could take
the focus away first. Nothing holds focus it was not given by a tap now, so
there is nothing to take back.

The sidebar's new-chat button is a `FloatingActionButton` over the profile and
settings tiles, which is the one part of the sidebar that is not a list of
chats and has room to its right. Not `Scaffold.floatingActionButton`: the
sidebar is deliberately a `Material`, since an inner `Scaffold` would shadow
the one holding the drawer.

## Development

- Build/test Linux desktop inside the `flutter-dev` toolbox (host lacks
  cmake/ninja/clang++): `toolbox run --container flutter-dev flutter build linux --debug`.
- UI runs forwarded to host: `toolbox run --container flutter-dev flutter run -d linux --debug`.
- Web: `toolbox run --container flutter-dev flutter run -d web-server --web-port 8087 --web-hostname 127.0.0.1`.
  Nothing runs the app in a browser here, so a web-only regression in the UI is
  caught by reloading the page.
- Codegen: `dart run build_runner build` (freezed + json_serializable).
- Analyze: `flutter analyze`. Tests: `flutter test` — see `test/CLAUDE.md`.
- The repo is not `dart format` clean and is not meant to be; match the file you
  are in rather than reformatting it.

## Dependency note

Freezed 3.x requires `abstract class Foo with _$Foo` (not just `class`).
Build runner capped at `^2.15.1` to stay compatible with freezed 3.2.5's
analyzer constraint. riverpod_generator dropped due to analyzer conflict with
freezed; we use manual Riverpod providers.
