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
title model, the classifier model, `approveMode`, `environment`, `appIcon`, and
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

### The conversation log

`conv.jsonl` is a log of `ChatRecord`s, one per line, appended as a turn happens
and never rewritten. It was a JSON document, and a document has to be written
whole to stay parseable — so it could only be written once a turn was over, and
a turn killed halfway left nothing at all. A line is complete the moment it is
written, so the only thing a kill can now cost is whatever had not been appended
yet. That is what makes an interrupted turn something to offer to continue
rather than something to apologise for.

Six records. `message` opens one — before it holds anything, which is what the
empty assistant message at the head of a turn is — and its `siblingOf` names
what it is an alternative to, or nothing at all, which puts it on the end of the
thread being read; `replacesSibling` takes that one away rather than joining it.
`part` is one part of it, at an index. `append` is more text
on the end of the part at an index. `turnEnd` closes the turn and says why:
`done`, `aborted`, or `error`. `select` says which of a message's alternatives
to read. `rewind` forgets a message and everything below it.

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
rewriting it, which is the one thing the format exists to avoid. It is also the
one record whose meaning did not have to change when the log became a tree: in a
conversation of one thread, everything below a message is everything after it.

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
carries eleven copies of that turn's records and pays for them on every open.
Threads make that harder rather than easier: the copies are no longer dead
records to drop, they are alternatives the user can still read. So compaction
now starts with deleting threads, which is a thing to offer rather than to do.

#### Threads

The log describes a tree, and `replayTree` walks the one path through it that is
on screen. An edit or a regenerate no longer discards the turn it replaces: it
opens a message naming the one it stands beside, and the two are threads at that
point in the conversation. `Chat.messages` is the thread being read;
`Chat.branches` is, for each message on it that has any, the alternatives
written there — which is the `2/3` under the message and what its arrows move
between.

**The tree edge is `siblingOf`, not a parent.** `MessageRecord` carried an
unused `parentId` from the first version until this landed, and naming a parent
there cannot express the case that matters: editing the *first* message of a
chat produces an alternative whose parent is nothing, which is the same null a
message written before threads uses to mean "on the end of what is already
there". Naming the **sibling** has no such collision at any depth, including the
root, and it leaves every existing log exactly as it was — naming nothing, each
of its messages continues the one thread it has, which is what they meant when
they were written. There is no migration and nothing to version. `parentId` went
with it, having never been written or read; the parent is `replayTree`'s to
compute, and a `Message` on its own cannot answer which thread it is on.

It is a field rather than a record of its own, which is what this was first
built as. A separate `branch` record written before the message it introduces
splits one fact across two lines, and the format's whole claim is that a line is
complete the moment it is written — so it needed a pending map in the reader, an
ordering contract in the writer, and a comment at each end saying so. A field
has no order to get wrong.

Which thread is being read is itself a record. `select` is appended as the user
cycles, so what they were reading survives a reload; the last one written wins,
the way a superseded part does. With none, a branch point shows its newest
thread — a regenerate just asked for is the one to be looking at.

**A turn that said nothing is replaced rather than kept beside.** Stop a turn
before the model has written a word and regenerate it, and there is nothing on
the thread it would leave behind: a `1/2` whose first page is blank is worse
than no counter. `Chat.worthAThread` is the rule, and it asks two things —
whether the reply holds any parts, and whether it is still the end of its
thread. The second is what stops the tidy-up eating a conversation: kill a turn,
type something else, and the empty reply now has everything said since hanging
under it, which is not something to delete for a counter. An edit never meets
this, since the message it branches at is a prompt the user typed.

Replacing is `replacesSibling` on the same record rather than a `rewind` written
after it, for the reason `siblingOf` is a field at all: a turn standing in place
of another is one fact, and one fact is one line. Written as two records it
worked, and only in that order — the new message has to join its siblings while
they are all still there, or it lands on the end of whichever was left instead
of beside them. That is a write-order contract, which is what this format is for
not having. `replayTree` does the same two steps in the one arm that reads the
record, and the order lives in the four lines that do them.

`replayTree` stays as liberal as `replay` was. A `branch` of a message that has
since been deleted is not an error: the message it introduces goes on the end of
the thread instead, which is where it would have gone had the record never been
written at all.

What a branch does to the conversation is said twice, deliberately.
`Chat.withTurn` is what `replayTree` will make of the records once they are on
disk, worked out in memory so that pressing Regenerate does not cost a reload of
the log to draw. The two have to agree, and what keeps them honest is a test
asserting that the chat on screen and the chat a reload reads are the same one,
branches included.

Moving between threads is deliberately *not* worked out in memory, and that is
the split. `selectThread` and `deleteThread` append their record and load the
chat back, because which messages another thread leaves live is `replayTree`'s
to answer, and a second version of that walk is a second version to disagree.
That reload is why `ChatController` refuses a thread change while one is still
in flight: a held-down arrow would otherwise compute each move from a
conversation the previous load is about to replace.

Starting a turn on a thread the model has not been down is where the session
has to be forgotten, and that rides on `sendPrompt` as `replaces` rather than
being a `resetSession` the caller makes first. Same reason `history` does — see
"The projection": a separate call is one a caller can forget, and forgetting it
is silent, the model answering fluently from the thread the user has just left.

#### The projection

`replay` reads the log for the UI; `projectionOf` reads it for a provider, and
the two are what the log exists to make possible. A domain `Message` is a whole
turn and a turn is several provider responses — think, call a tool, look at the
result, think again — so it splits one assistant message back into one
`LlmMessage` per response, each followed by the `tool` messages answering its
calls. Handing a response's thinking back with a later response's tool calls is
rejected, so the split has to be right. Named `projectionOf` rather than
`project`, which everywhere else here is the directory a chat lives in.

That is what `responseId` is for. `BuiltinAgent` names each step before it runs
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

`endsUnfinished` is the whole of the classifier: the last message of the thread
being read, if it is a reply, and the last record naming it. `TurnEnd.resumable`
decides — missing means the process was killed and `error` means the turn gave
up, and nobody chose either; `done` finished and `aborted` is the one case where
the user has already said to stop. It is on the enum because two places ask, the
log's reader and the controller closing a turn, and they have to agree or the
offer flickers on the next reload. `chatFrom` is the classifier and `replayTree`
together, and it is what both stores load through.

Only the **last** reply is asked about, and that is the rule rather than a
shortcut. Every turn is marked, so a reply in the middle of a conversation can be
left open — kill a turn, then type something new instead of carrying on, and that
one stays open for good. It is still not resumable: resuming appends to a
message, so continuing one from the middle would put new work before turns that
already happened and that the model has since built on. Nothing reads it either,
so nothing closes it; a tidy-up record would be written for no reader.

**"Last" is now the last of the thread being read**, which means the offer moves
as the user cycles. Kill a turn, regenerate, and step back: the reply that was
killed is the end of *its* thread, so it is offered again and carrying it on
still only ever appends. That is the same rule and not an exception to it — the
reason the middle of a conversation is refused is that there are turns below it,
and on that thread there are none. It does mean `Chat.unfinished` is answered per
thread rather than per chat, so the `ResumeBar` can appear and go as the arrows
are pressed.

A turn killed before the model said anything is the one case with nothing to
step back to: it is offered to be carried on *and* it is what
`Chat.worthAThread` refuses, so pressing Regenerate takes away the reply
Continue would have appended to. Both are right — there is nothing in it either
way — and they are on screen together only because the offer is about the turn
while the counter is about what the turn produced.

One assumption is worth naming because it is invisible: an open log means nothing
is running only because a turn cannot outlive the process running it. The
foreground service does not break it — the turn stays in the app's own isolate
and the service only keeps that process alive, so the UI that comes back is the
one that never stopped listening. A second engine would break it, and that is
the reason there is not one. See "Staying alive off screen".

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

`BuiltinAgent.resume` is `run` without the task, over a session rebuilt from
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

`BuiltinAgent` is mini-swe-agent's control flow in Dart: render the system and
task prompts, ask the model, run the tool calls it made, show it the results,
repeat. What is still upstream's, and it is worth knowing which parts are: that
skeleton (`DefaultAgent.run`/`step`/`query`/`execute_actions`), the one `bash`
tool and its schema, the observation JSON `observation()` writes — key for key,
including the 10,000-character threshold and the 5,000-character head and tail —
and the shell contract `LocalShell` keeps, which is `local.py`'s; see "Running
the commands". Prompt furniture too: the `cd` prefix rule, the
`<system_information>` block, the `cat <<'EOF'` and `sed -i` examples.

Everything else has diverged, and one divergence is the protocol rather than a
detail. It exits when the model replies with no tool calls — the reply text is
the answer — or when it hits the step limit. This is the native API contract
models are trained on (text-only message = finished answer, tool calls =
continue), which works reliably across model sizes. The codebase previously
used mini-swe-agent's `COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` marker as the
termination signal, but that protocol was a forcing function for weak models on
SWE-bench and failed on exactly the small models this app targets: they called
the marker without writing answer text, leaving the sub-agent runner with an
empty buffer. Upstream still holds the opposite rule — a reply with no tool call
is a format error it retries — so the one behaviour the old name would have
predicted is the one this does backwards.

What is not upstream's at all, and it is most of this directory: cost tracking
and the cost limit that is upstream's real budget (this counts steps instead),
the format-error machinery, the trajectory serialization, and litellm — `llm/`
is a thousand lines of streaming HTTP clients where upstream makes one blocking
call. Nor sub-agents, `ask_user`, web search, approval modes, sessions that
outlive a turn, resume, or the projection.

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

`BuiltinSession` holds the conversation as the model sees it, per chat, for as
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

A `RateLimitGate` is built per turn in `BuiltinBackend.sendPrompt` and shared by
the parent `BuiltinAgent` and every sub-agent it spawns: it bounds in-flight
`LlmClient.stream` calls to `BuiltinOptions.maxConcurrentLlmRequests` (4
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
continue for `BuiltinOptions.rateLimitRetryBudget` (5 min default) with
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
is, whether the process has an environment, `FileHandoff` (see "The workspace
explorer" for why it is the one thing here with three implementations), and
`platformPersist`: on the web that is `navigator.storage.persist()`, without
which IndexedDB is evictable and a chat can be gone on the next visit because
something else wanted the space. A browser that refuses leaves the app working,
just evictable again. Everywhere else it is a no-op, because a directory on a
disk is already as durable as the app is.

`BuiltinBackend.webSearch` is required rather than defaulted for that reason —
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
`ChatRepository` and arrives with the prompt, so it is a `BuiltinAgent`
parameter beside `approve` rather than part of `BuiltinOptions`, which holds
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
`BuiltinOptions.maxConcurrentSubAgents` (8 by default — deep-research can fan
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

##### Their own transcripts

A sub-agent writes one, at `<chat>/subagents/<callId>.jsonl`, and it is a
`ChatRecord` log exactly like `conv.jsonl`. That is the whole design: `replay`
reads it, `projectionOf` puts it back in front of a model, and a missing
`turnEnd` means what it means anywhere else. A status file would have served
the reporting and been thrown away the day sub-agent transcripts became
something to look at.

The call id is the only id there is. The transcript holds one message — a
sub-agent's whole run is one turn — and it is named after the call that spawned
it, which the parent's own log already holds. So nothing has to be written down
to pair the two, and carrying one on adds to that message rather than writing a
second beside it.

`TurnRecorder` is what writes it, the same class `ChatController` uses for the
conversation. It was pulled out of the controller for this: turning a turn's
events into parts and records is the same job either way, and a sub-agent with
its own weaker version would be one whose kill leaves a file nothing can read.
The controller keeps the seven lines that mirror the parts into Riverpod state
and passes them as a callback; a sub-agent passes none. The one thing the
recorder does not write is the record opening the message — one level up that is
`send`'s job, and for a sub-agent it is `_recorderFor`'s.

`SubAgentLog` is a port rather than a call on `ChatStore` because the backend is
the only thing that sees a sub-agent's events at all: they never reach the
controller that writes `conv.jsonl`, so the store's owner never has them.

##### Carrying one on

`BuiltinBackend._reviveSubAgents` runs before the resumed session is built. A
`task` call in the interrupted reply whose result never landed is answered by
running its sub-agent on, over a session rebuilt from its own transcript — which
is `BuiltinAgent.resume` and `projectionOf`, the same three steps the user's
Continue takes one level up, so there is one mechanism and not two.

**Nothing asks, and nobody is told.** "Carrying on an interrupted turn" says
nothing resumes on its own and the three routes out are the user's — that is
about the top of the conversation, which is theirs. A sub-agent is machinery
inside a turn they have already said to continue, so reviving one needs no
button, no tool argument and no prompt telling the model the mechanism exists.
Reviving is also what makes the resumed turn honest: a fan-out of 75 that lost
five keeps the seventy that finished.

The revived results go out as ordinary `ToolResultEvent`s before the agent's own
events, so the reply on screen and the records in `conv.jsonl` both gain them
through the path every other result takes. They are folded into the history
first, so the session is projected from a conversation that already has them
rather than patched afterwards.

A call with no transcript is left alone. It never started, so there is nothing
to carry on and the projection's "this was interrupted" is the honest answer —
which is also why the two have to stay side by side.

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

### Staying alive off screen

Android kills a process nobody is looking at, and a turn is minutes of a model's
time and a half-written reply. `AgentService` is a `dataSync` foreground service
that says the process is busy; `TurnKeepAlive` starts and stops it from
`AgentBackend.runningTurns`, which is the chats `BuiltinBackend` has an agent
running for. It is a `ValueListenable` of ids rather than a count so that Stop
can abort each one, which is also why there is no `abortAll` — one way to stop a
turn.

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
finishing and `AgentService.busy` is false. Cached unconditionally it would be a
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

The drawer is sized by what is in it, up to the whole screen. It used to stop at
seven tenths of the height, which is a tool's output cut short and a third of the
screen left empty under it. It is a route, so the back key closes it and nothing
had to be written for that.

What can be done to a message is a row under it rather than a menu, uncovered by
hovering the message or, where there is no pointer to hover with, by touching
it. Left to right: which thread this is and the arrows between them, delete,
then Edit and Regenerate. The counter and the arrows are there only where there
is more than one thread — `1/1` and two dead arrows say nothing — while delete
is offered whatever the count, since deleting the last thread at a point is the
conversation being cut off there and is worth being able to do. The arrows stop
at either end rather than wrapping: one that comes back round to where the
reader started reads as having done nothing. Deleting asks first, and the
question says whether anything is left, because those are two different things
to be agreeing to.

The row keeps its height whether or not anything is in it, so the conversation
does not shift under the pointer the moment the icons appear. The reveal is a
`Listener` rather than a `GestureDetector`: a raw pointer listener sidesteps the
gesture arena, so one touch both places the caret in the bubble's
`SelectableText` and shows the actions. It writes a `ValueNotifier` rather than
calling `setState`, so uncovering the icons does not rebuild the message's
labels behind them.

### The chat page

One app bar, whichever layout it is drawn in. Narrow, the sidebar is `ChatPage`'s
own drawer rather than a shell's — two bars stacked was the app's name over the
chat's, saying nothing twice. What it shows follows the conversation: the mark
and "Entoli" while the list is at its top, the chat's title and project once it
is not. A chat too short to scroll is always at the top, so it keeps the mark.

`_SidebarDrawer` is that drawer, and the only thing it says is a width: below
Material's compact breakpoint it takes the whole screen, since 304dp of panel on
a phone leaves a strip of chat nobody can read and nothing else. A width rather
than a platform check, which is how every other question of room is answered
here — the shell's own 900 above it, the bubble's share of the line below.

The back key takes two halves, and a `Drawer` only brings one. An open one puts a
`LocalHistoryEntry` on the route it sits in, and a route holding one answers a
pop by dropping the entry rather than leaving — so if the press arrives, the
right thing happens. It does not arrive. Android forwards one only while the
framework has claimed it through `SystemNavigator.setFrameworkHandlesBack`; that
is dispatched off a `NavigationNotification`; and the only things that recompute
one are the `Navigator`'s route list changing and a `PopEntry` registering.
Opening a drawer is neither. So the platform still holds the `false` it was told
when the app had one route, keeps its own callback disabled, and finishes the
activity without Flutter hearing anything.

`PopScope(canPop: false)` in the drawer is that `PopEntry`, and claiming the key
is what it is for — not the pop, which the history entry would have handled.
`ModalRoute` consults its pop entries *before* `LocalHistoryRoute` gets a say, so
the scope does reach `popDisposition`, and the `doNotPop` it forces is what makes
the notification claim. After that the claim is all of it: the press comes in,
the route declines to pop, and `onPopInvokedWithResult` closes the drawer by
hand.

This shipped broken once, and why is worth more than the fix. A widget test
presses back through `handlePopRoute`, which calls the framework directly and
never consults the platform — so the missing half was exactly the half the test
could not see, and it passed against a build that closed the app on a phone.
Anything asserting about the back key needs `frameworkHandlesBack` beside the
press.

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

The syntax is parsed in `BuiltinBackend` (`_command` / `_mention`), not in the
repository or the UI: `conv.jsonl` stores the message as typed, so a regenerated
turn re-parses to the same thing. `activeCompletionToken` in the composer has to
agree with those two patterns — anything the menu offers has to dispatch.

`/name args` expands to the command's body with `$ARGUMENTS` substituted (or
appended); a name the library does not know is left alone, because it is more
likely a path. `@name` stacks that agent's prompt under the system message.

`completions` is therefore **not** on `AgentBackend`: `completionsProvider`
reads the library directly and is synchronous.

### Resending a message

Edit and regenerate run the turn again as another thread beside it, rather than
discarding what was there. The live session still holds the thread being left,
so `resetSession` drops it and puts back `projectionOf` the messages above the
branch — thinking, calls and results and all. This is where the "conv.jsonl is
the source of truth, re-inject context" rule is exercised, and the projection is
what makes it true rather than approximate. Only the turn being replayed carries
its own attachments back; the messages above it name theirs.

**They branch at different messages, and that is what decides where the counter
lands.** An edit is a new prompt, so it is a thread beside the prompt it
replaces and the `2/3` is under the user's message. A regenerate is a new reply
to a prompt that has not changed, so the prompt is the branch point and is not
written a second time — the counter is under the reply, which is the message the
arrows actually move between. That is why `regenerate` no longer goes through
`_promptFor` to rewrite the exchange from the top: it did, and it would have put
the counter on the wrong message.

Continuing an interrupted turn is deliberately neither of these. It adds to a
reply that is already there, so there is nothing to branch — see "Carrying on an
interrupted turn".

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

### The workspace explorer

A workspace is where the agent's work lands, and until now the only way to see
it was to leave the app. `WorkspaceTile` on the chat, project and app settings
pages opens `WorkspacePage` over one folder — the chat's own `workspace/`, the
project's shared one, or the default project's, resolved by the page that knows
which it is. The default project's is reached from the app's settings because
there is nowhere else it could be: every other project opens its own from its
settings page, and the default project has none — it is the data directory, so a
settings page for it would be the app's own said twice.

Listing, making a folder and deleting go through the config's `FileSystem`
(`listWorkspace`, `createFolder`, `deleteEntries`), so they are the same code on
a disk and over IndexedDB and are offered wherever the explorer is. A typed
folder name is sanitised by `safeRelativePath` like anything else joined onto a
workspace — `../` is a name a folder can be asked for. Deleting looks each path
up rather than trusting what the listing said it was, since a selection is held
as paths and the listing under it is re-read.

Everything else the page can do is `FileHandoff`'s, and every route is gated the
way `Shell.canRunCommands` gates the agent's commands. The three platforms do
not differ in degree here, they differ in kind — and so there are three
implementations, not two. The conditional import splits `dart:io` from
`dart:js_interop`, which it has to: `Process` will not compile in a browser and a
`Blob` will not compile on the VM. Desktop and Android are then chosen at
runtime in `platformFileHandoff`, because they share `dart:io` and agree on
nothing else here. Choosing rather than branching is the point: a class that
answered both would carry an `if (Platform.isAndroid)` in every member, and
every future member too.

- **Desktop** has a file manager and a registry of viewers, and `url_launcher`
  reaches both: `reveal` opens the current folder (the app bar's button) and
  `open` opens a file, which is the same call on a different path. It needs no
  chooser of its own — the file manager is already pointed at the workspace —
  and it has no share sheet, so a selection there is only ever deleted.
- **Android** has the share sheet, both ways. `export` sends a selection through
  `Intent.createChooser`, so every app on the device is on offer rather than a
  default winning silently; `open` is an `ACTION_VIEW`. Files come back in the
  same way, and only that way: another app shares to Entoli. It is not the only
  route out any more — a `DocumentsProvider` puts the workspaces in the Files
  app, for the other app to browse rather than be handed something. Both are
  below.
- **A browser** opens a file as a blob in a new tab, which is what lets the
  browser preview it, downloads a selection, and takes files in through the
  chooser `<input type="file">` already is — `webkitdirectory` for a folder,
  whose `webkitRelativePath` is what keeps the folder's shape.

`exportKind` is the one thing the port says about presentation, and it says the
*kind* rather than the words: a share sheet and a download are not the same
promise to the user, but which word and which glyph say so is `WorkspacePage`'s
to decide. Null is a platform with nowhere to hand a selection, which is what
takes the export button off the desktop toolbar — selecting itself stays, since
deleting is the filesystem's rather than a route out of the app.

A selection replaces the browsing actions rather than sitting beside them: the
app bar is the filesystem's verbs on what is picked, and the FAB stays the route
out of the app, which is the one thing a platform can be without.

Neither a share sheet nor a download takes a folder, so a selection with one in
it goes as a single zip (`zipEntries`, in `lib/data/` rather than `local/` or
`web/` because it is written against the `FileSystem` and both sides use it).
Several plain files stay several, which is what `ACTION_SEND_MULTIPLE` is for. A
selection is one folder's — leaving the folder clears it — which is what lets
Android's staging directory stay flat, and why nothing checks for two files of
the same name in it.

Coming the other way, an `IncomingFile` is deliberately **not** its bytes. A
batch arrives with as many files as its source chose to send and then waits on
screen while the user picks a workspace, so held as buffers it is a video's
worth of heap for as long as that takes — and on a phone, long enough to be
killed for it. What each one holds instead is whatever its own source already
had: `IncomingBlob` in a browser, where a `File` is a handle to bytes that have
not been loaded yet, and `IncomingStaged` on Android, which is the copy
`FilesChannel` already made. `IncomingBytes` is the trivial third, for bytes
genuinely in hand.

`writeIncoming` makes room and hands over a target; `writeTo` decides what
putting it there means. That split is where the traversal boundary lives —
`safeRelativePath` runs once, before dispatch, so no variant can open a hole in
it — and it is why the writes stay sequential: doing them at once would put
every file's bytes in memory together, which is the whole thing being avoided.
Only the folders are batched, because `create` on the web opens a read-write
transaction before it looks, and a folder upload names one directory hundreds of
times.

`IncomingBlob` lives beside `WebFileHandoff` rather than with its siblings in
`lib/domain/`, since it holds a `package:web` type. That is also why
`IncomingFile` is `abstract` and not `sealed` — the variants are deliberately
not all in one library, and nothing switches on them.

That staging directory is the other thing worth knowing about the Android half.
Everything handed to an intent is a **copy under the app's cache**, never the
workspace file itself, because a `FileProvider` only mints URIs under the paths
in `res/xml/file_paths.xml` and one `<cache-path>` is the whole of that file.
The alternative was a `<root-path>` exposing the data directory by path for the
sake of not copying, which is a worse trade on a directory holding `settings.json`
and every chat. It costs a copy per open; workspace files are the agent's output,
and the ones big enough to notice are rare.

#### Sharing to Entoli

`MainActivity` carries `ACTION_SEND` / `ACTION_SEND_MULTIPLE` filters, and so
does the `PromptIcon` alias — only one of the two components is enabled at a
time, and a share must not stop working because the user changed the icon.

`FilesChannel.receive` copies whatever the intent carries into `cacheDir` **at
once**, from `onCreate` and `onNewIntent` alike: the read permission on those
URIs is granted to the task and dies with it, and the user takes a while to pick
a workspace. The intent's action is then cleared, so an activity recreated from
the same one does not stage the share twice. A batch arriving with nothing
already waiting empties the directory first — a share the user backed out of is
never claimed, and nothing else would ever delete its copy.

Dart claims them from `IncomingShares`, which wraps the app in `main` rather
than living in `AppShell`: a share has to be offered a workspace over whatever
is on screen, and a `Navigator` to push that onto only exists below
`MaterialApp`. It reads twice over and needs both — once after the first frame,
for the share that launched the app and was staged before Dart was listening,
and once per `shareArrived`, for one that arrives while the app is already up.
Reading empties the queue, so a share is offered a workspace exactly once.

The nudge is what carries the cached engine's case, and it is the reason there
is one. A share into an activity whose engine was cached runs `onCreate` but not
`main`, so `initState` does not fire again and the first-frame read never
repeats — but the channel is still registered and the widget still subscribed,
so the invoke lands. See "Staying alive off screen".

`ShareTargetPage` is that offer: every workspace Entoli has, as a list — the
default project, each project beside it, then each chat's own — and picking one
writes the files there and closes. Nothing else is on it, because a share
arrives with nowhere to go and asking is the whole of what the page is for.

A path that arrived from outside is sanitised by `safeRelativePath` before it is
joined onto anything: the sharing app wrote it, and `../../settings.json` is a
name a file can have. Folders in it are kept — that is what makes a folder
upload survive — and only the segments that would climb are dropped.

A staged copy is **moved** into the workspace rather than read out of it. The
cache and the data directory are one volume, so the move is the real path and
the bytes never enter this process; the copy it falls back to is there because
"one volume" is an assumption about a device rather than a guarantee.

Moving consumes the copy, which is what makes the staging directory tidy itself
and is also the reason `FilesChannel` prunes it on the way **out** rather than
on the way in. Dart now holds the staged paths until a workspace is picked, so a
second share arriving while that page is open would delete the paths the page is
still pointing at. At `takeShare` there is no such hazard: only one batch is ever
offered at a time, so anything left beside the batch being handed over is an
earlier one nobody claimed.

#### The workspaces in the Files app

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

**The tree is the on-disk layout, not a view of it.** The root is the default
project — which *is* the data directory — so its children are that project's
shared `workspace/`, a folder per chat in it, and a folder per named project,
which is where `projects/` already puts them; a named project holds the same two
kinds of thing. Each is named after whatever owns it, since every workspace is a
directory called `workspace`: a chat by its title, a project's shared one by the
word the explorer uses.

A document id is either a project — `:` for the default one, `:<name>` for a
named one — or a path relative to the data directory, which is what every file
in a workspace is. Neither can be read as the other: a project name is never
empty and a real path always starts `workspace`, `chats` or `projects`.
`workspaceDepth` is the whole of what a path can reach — it has to name
`[projects/<name>/]workspace` or `[projects/<name>/]chats/<id>/workspace` before
anything under it resolves, so `resources/`, `subagents/`, `conv.jsonl` and
`settings.json` are not in the tree and cannot be asked for. `projectOf` holds a
project id to `AppConfig.projectDir`'s rule for the same reason, and why both
are needed is worth saying: a tree grant lets the app holding it compose ids of
its own, so `:..` is an id that arrives rather than one that was handed out.

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

### The app icon

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

Every channel — this one, `ForegroundService` and `FilesChannel` — is registered
when the engine is created rather than on each attach, and holds the application
context. That is forced by the engine outliving the activity: see "Staying alive
off screen".

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

The settings page is five sections plus deleting everything: **New chats**
(default model, title model), **Workspace** (the default project's, which has
nowhere else to be reached from), **Appearance** (app icon), **Agent** (command
approval mode, classifier model, providers), **Environment**.

### Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` and
`OptionalModelPicker` (each a field over the model list, sharing the loading and
failure states every page would otherwise spell out) over
`ProviderModelSelector` (which owns every rule about the pair), the
`Default`-plus-reset pairing, `LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs, `showAnchoredMenu`, and `AttachmentChip` /
`AttachmentStrip`.

`showAnchoredMenu` is a menu under a button, as a **route**. A `MenuAnchor`
draws into an overlay instead, and an overlay is not popped by anything: the
back key passes through it to whatever is behind, which beside the chat is the
app leaving and inside the drawer is the whole sidebar closing. Neither is what
back means over a menu. `PopupMenuButton` gets this right by pushing a route, and
this is the same push without having to be the button — the project switcher and
the add-provider row keep the buttons they had. It takes the button's own
context, so both callers reach for a `Builder`: their build context is the whole
section, and a menu anchored to that hangs off the wrong edge.

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

Giving focus away is the composer's rule; taking it back when the keyboard goes
is the app's, and is the next section.

The sidebar's new-chat button is a `FloatingActionButton` over the profile and
settings tiles, which is the one part of the sidebar that is not a list of
chats and has room to its right. Not `Scaffold.floatingActionButton`: the
sidebar is deliberately a `Material`, since an inner `Scaffold` would shadow
the one holding the drawer.

### The keyboard and the caret

Android closes the keyboard on a back gesture and says nothing about it but that
the view insets fell — and on touch the framework deliberately never unfocuses a
field for a tap outside it — so a field tapped once goes on holding the caret
over a conversation nobody is typing in. `FocusFollowsKeyboard` wraps the app in
`main` and is the whole of the answer: it remembers what held focus while the
insets were up and drops it when they fall to nothing. It is app-level because
both halves already are, `MediaQuery` and the `FocusManager`, so every field
gets it and the composer keeps no focus code at all.

It reads `MediaQuery.viewInsetsOf`, so it has to be above every `Scaffold`, which
is what takes the bottom inset out of what it lays out. Being at the root is also
what makes it survive: this was in `_ComposerState` first, whose state goes every
time the `QuestionPanel` takes the composer's place, so its "the keyboard is up"
flag could be false with the keyboard up. Then it was deleted outright, read as a
mechanism that existed only to undo the focus requests going away. It was not:
the insets are the only report of the keyboard closing there is, and the caret
came back with them.

What it remembers is a node, rather than asking what holds focus once the insets
have fallen, because by then focus may have moved — to a pushed route's scope
when the `+` menu opens, or to a reply's `SelectableText`, which is a read-only
`EditableText` and closes the keyboard by taking the focus away from the field.
Unfocusing either of those breaks something that was working, and `hasFocus` on
the node the keyboard was up for is the whole of the test. The gap it leaves is
focus moving straight from one field to another, where the insets never fall and
the second field keeps its caret; closing that means watching every focus change,
which is how a reply's selection would get dropped.

## Releasing

Publishing a release starts two workflows that share nothing but the event:
`release.yml` builds and attaches the Android APK, and `pages.yml` deploys the
web app from the same tag. Either can fail without the other, and only the
first checks the tag against pubspec — a version disagreement stops the APK and
deploys the site anyway. Linux is built by `debug-build.yml` on request and is
not part of a release at all.

`release.yml` attaches one signed APK with a provenance attestation beside it.
There is no Play channel and so no App Bundle: the file on the release is the
file that gets installed. It is named `entoli-<version>.apk` — a person
downloads it, so it carries the app's name rather than the package's, and the
name is composed once in the build job because the attestation records its
subject by name.

**The version is `pubspec.yaml`'s `version:` and nothing else.** The workflow
refuses to build when the tag disagrees with it, since an APK reporting a
version nobody released cannot be talked out of it afterwards.

**The Android version code is derived from that version rather than stored**,
as `major * 10000 + minor * 100 + patch` — 1.0.0 is 10000, 1.2.3 is 10203. So
pubspec carries no `+build` suffix: a suffix would be a second number to bump
and so a second number to forget, and forgetting it means a release that will
not install over the one before it. **Minor and patch must stay below 100**, or
1.0.100 and 1.1.0 compute the same code; the workflow fails rather than
shipping the collision. The debug builds are a separate application id
(`.debug`), so the run numbers `debug-build.yml` gives them are never compared
against these.

**Signing material never enters the repository.** Four secrets —
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD` — are decoded into the runner's temp directory, never
into the workspace an artifact is uploaded from.
`android/app/build.gradle.kts` reads the environment first and
`android/key.properties` second, which is deliberate twice over: a stray
properties file in a workspace cannot then change what CI signs with, and a
password survives the environment unaltered, where `java.util.Properties`
reads a backslash in a value as an escape and would corrupt one.

**Where nothing is configured the release build falls back to the debug key,
and that fallback is what the checks are built around.** It keeps
`flutter run --release` working on a machine with no keystore, and Gradle
generates a debug keystore on any runner that lacks one — so a build with the
secrets missing still *succeeds*, and ships an APK that nothing installs over
at the next release. So the run fails before it builds if any of the four
secrets is empty, and asserts on the signer certificate afterwards;
`CN=Android Debug` in `apksigner verify --print-certs` fails it. Gradle applies
the same rule to its own inputs — all four settings or none, since a
half-filled `key.properties` would otherwise reach AGP as a signing config with
null members. The signer's SHA-256 goes in the run summary, because a change in
it is the one thing a user cannot recover from.

**The keystore is the maintainer's and nothing here can regenerate it.**
Android identifies an app by its signing key, so losing it ends the ability to
update Entoli for anyone who already has it. Making one, once:

```sh
keytool -genkey -v -keystore entoli.jks -keyalg RSA -keysize 4096 \
  -validity 10000 -alias entoli
base64 -w0 entoli.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS
gh secret set ANDROID_KEY_PASSWORD
```

**Two jobs, because the one holding the keystore should not also hold
`contents: write`.** The publisher attests the APK with
`actions/attest-build-provenance` and attaches both files, so a download can be
checked against the build that made it:

```sh
gh attestation verify entoli-1.0.0.apk --repo Yiannis128/agent-chat
```

Splitting also means a failed upload re-runs against the artifact that was
already built and checked rather than a rebuild that would have to be trusted
to match. **A job that never checks out has no git remote**, which is the trap
in that split: `gh release upload` reads the repository from it and fails with
`not a git repository` pointing at the runner, so the publisher names the
repository explicitly.

`workflow_dispatch` takes a tag and rebuilds an existing release for the same
reason: recreating a release to retry a publish changes its timestamp and
notifies every watcher a second time.

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
