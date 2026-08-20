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

### The sidebar's list

Chats sit under a heading — Today, Yesterday, Previous 7 days, Previous 30 days,
then the month, with the year on it where that is not this one. Each row was a
title over its own timestamp, which is a date the reader has to compare against
eleven others to place; the heading places all of them at once, and the row is
the title and nothing else.

`groupChatsByDate` is the whole of it, in `chat_groups.dart` and away from the
widget so the boundaries can be tested at a date of the test's choosing —
`now` is a parameter for that reason. It takes the headings in the order the
chats come in rather than ranking them, which is sound because the list is
sorted newest first: from there a chat can only ever land in the group it is
already in or one further down. Days are counted on a UTC calendar, since a
local day either side of a clock change is 23 or 25 hours and yesterday would
round to today.

**Search reads the titles and nothing else.** Searching what was *said* means
reading every `conv.jsonl` off disk on every keystroke; the titles are already
in memory, being what the list draws. What is matched is the title as shown, so
a chat the title model never named is found under `(untitled)`. The field is
there whenever the project has chats in it — it goes with them, not with the
results, or a search that matched nothing would take away the only way to undo
itself.

The query is a `ValueNotifier` the list listens to rather than `setState` on the
sidebar: a keystroke changes the list, and the project switcher above it has no
business rebuilding to answer one. It holds the *text* rather than the field's
`TextEditingController`, which is a `ValueListenable` and would have done — its
value is the text and the caret together, so moving the caret in the search box
would regroup the whole list for nothing. Same reason `Composer` keeps
`_canSend`.

Switching projects clears it, for the reason switching clears the selected chat:
the list the query was written against has just been replaced, and kept it would
answer a project the user has only just arrived in with "nothing matches".

#### Pinned chats

A chat can be pinned from its sidebar context menu. Pinned chats sit under a
"Pinned" heading ahead of every date group, newest first among themselves, and
a single pinned chat still gets the heading — the pin is a fact the user set,
not a date the reader has to place. `groupChatsByDate` partitions on
`ChatState.pinned` before it groups by date, so the pinned group is always
drawn first and the date groups follow in the order they were already in.

`pinned` lives on `ChatState` rather than `ChatMeta` for the same reason
`tempTtlExpiresAt` does: the sidebar list holds `ChatState`s and reads the
flag off them without loading `meta.json` per chat per refresh. Pinning is not
a setting override — it is a state of the chat, like the TTL anchor — so it
belongs beside it.

**A pinned chat cannot be temporary.** `ChatRepository.pinChat` clears the
TTL anchor and sets the chat's `meta.tempChatTtl` override to `off` in the same
write, the way `keepExpiredChat` does — so `saveState`'s TTL resolution keeps
the chat non-temporary even if the app or project default later widens. The
chat settings page replaces the TTL combobox with "This chat is pinned and
cannot be temporary" while `state.pinned` is set, so the user is told rather
than left to find the field gone. The chat page title bar shows a pin in the
slot the hourglass countdown takes on a temporary chat; the two are mutually
exclusive, since pinning clears the expiry.

Unpinning clears `pinned` and leaves the TTL override at `off`, so the chat
stays non-temporary and the combobox returns with `Off` selected — the user
can re-enable temporary from there. Restoring the prior TTL state across a
pin/unpin was rejected: it is more state to track for a case nobody asked for,
and `off` is the honest answer for a chat that was just unpinned.

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
client per endpoint and rebuilds it when the URL or key changes; a provider that
lists no models is asked, and one that cannot answer contributes nothing rather
than failing the whole list. What it builds a client *with* is the endpoint's
own business: an `LlmEndpoint` is a config and, where reaching it is not the
ordinary thing, the client to reach it with — which is how the on-device
server's "may not be up yet" arrives without the registry knowing there is such
a thing. See "Running a model on the device".

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
explorer" for why it is the one thing here with three implementations),
`AssistantLaunch` (Android's assistant gesture, and a stub that never fires
anywhere else — see "Being the assistant"), and `platformPersist`: on the web
that is `navigator.storage.persist()`, without
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

**Which shell that is, is resolved rather than named.** `bash` then `sh` off
`PATH`, then `/bin/bash`, `/system/bin/sh`, `/bin/sh` — the two places a shell
sits that a `PATH` may not name, a stripped environment and Android, which has
no `/bin` at all. It was `/bin/bash` or `/bin/sh`, which meant a phone was
offered the `bash` tool and then failed every command it ran, one at a time.
Nothing found is `canRunCommands: false`, which is the browser's answer and the
honest one: the loop stops offering a tool there is nothing behind.

`LocalShell` prepends `exec 2>&1` to the script rather than merging two Dart
streams — a compiler's errors interleaved with its progress is the whole value
of reading them, and separate pipes arrive in whatever order they flush. It
spawns under `setsid` where that exists so a timeout can kill the process
group: a timed-out `npm install` that only loses its shell keeps downloading.
Whether `setsid` is there is learned by trying it, not by probing first.

Killing the group is not the same as closing the pipe, and the pipe is what the
run waits on. A command that puts a child in a session of its own — a daemon
started with `setsid`, anything a `nohup` left behind — leaves that child
holding stdout after the shell is gone, so the stream never ends. Waited on,
that is a turn nothing can finish: the agent is inside `await run.result`, the
timeout has already fired and killed everything it could reach, and there is no
second timeout behind it. So the output is read for a moment longer and the
subscription is then cancelled, which closes the read end. What that costs is
whatever the escaped child had still to say, which is the right thing to lose —
it is still saying it.

#### Bundled tools

What `/system/bin/sh` gets you is toybox: `ls`, `cat`, `grep`, `sed`, `find`,
`tar` and about a hundred and fifty more — and no `git`, which for a coding
agent is most of what is missing. So the app ships one. `git` and
`git-remote-http` are built against bionic with the NDK and ride inside the
APK, and `BundledTools` lays them out at startup; nothing else about the shell
changes, since the workspace, the `cwd` and `LocalShell` are all where they
already were.

**They live in the native library directory because it is the only place an
app may execute a file from.** Since Android 10, SELinux denies an app
targeting API 29 or higher `exec` on anything under its own data directory —
the W^X rule that kept Termux pinned at `targetSdk` 28 and off Play. The
library directory is not that, so a binary there runs. Two details follow from
it and both are load-bearing: the files must be named `lib*.so`, since that is
all the installer extracts out of an APK, and `useLegacyPackaging` has to be on
or they are mapped from inside the APK and there is no file to run at all. That
last one is APK-wide — AGP has no per-library lever — so every other native
library, the Flutter engine included, is stored compressed and unpacked at
install time as well. The APK shrinks and the installed app grows by what was
previously read straight out of it.

`<cacheDir>/tools` is a tree of **symlinks** into that directory rather than
copies. A copy would be another twelve megabytes, and — being in app storage —
one nothing may execute; the link is followed at exec time, so what the kernel
sees is the file where it is allowed to be. They are repointed on every install
rather than kept, because the library path carries an install-specific segment
and every link from before an update points at nothing.

The cache directory rather than the data one, for the reason the voice models
are there: `backup.dart` zips the data directory whole, and a backup carrying a
tree of links into an install that no longer exists is worse than useless. On
Android that is the support directory and so is not evictable — see "Where the
models live".

The environment is the rest of it: `PATH` with the system's own commands behind
ours, `GIT_EXEC_PATH` (git resolves `git-remote-https` and friends by name, so
the one helper is linked under each scheme it might be asked for), `HOME`,
`TMPDIR`, and `SSL_CERT_DIR` pointed at Android's own trust store, which is a
directory of hashed certificates rather than a bundle file. It is layered in
`LocalShell` beside the defaults that were already there, so the one place that
decides what a command runs under decides this too, and settings still win over
all of it — a variable the user set is the one that reaches the command.

**What was laid out and what the model is told about it are one value**, the
`Toolset` `install` answers with. They were a return value and a mutable global
next to it, which is an ordering nothing in the types insisted on: get it wrong
and git is on the `PATH` while the prompt never mentions it, which is the silent
half-failure this file keeps arguing against elsewhere.

**The toolset is frozen at build time**, and what is bundled is the whole of
what can be run directly: nothing downloaded may be executed, so there is no
package manager here and cannot be one. What lifts that is not another binary
but proot, and a whole Linux behind it — see "A whole Linux under proot" below,
which is where a package manager actually comes from.

Building them is `tool/bundle/`: `versions.sh` pins what is built and its
checksums, `build.sh` cross-compiles OpenSSL and curl statically and then git
against them, `stage.sh` puts the result where the APK packages it from. Three
adjustments make git build for bionic, and only three — `NO_OPENSSL=1` (git
has its own SHA), `android-compat.h` for `pthread_setcancelstate`, which bionic
does not have at all, and dropping `-lpthread`/`-lrt`, which bionic folds into
libc. The output needs nothing but `libz`, `libdl` and `libc`, all of which
Android already ships. About 12 MB an ABI, which is why nothing here is checked
in: CI builds it through `.github/actions/bundled-tools`, cached on the recipe
and the versions, and the release build refuses an APK that came out without
git in it.

That also means git, curl and OpenSSL are **ours to update**: nothing on the
device does it for us, so a CVE in any of them is a version bump in
`versions.sh` and a release.

#### A whole Linux under proot

A bundled binary is one binary. What a coding agent actually wants is a package
manager, and on Android that is the thing W^X takes away: since API 29 SELinux
denies an app `exec` on anything under its own data directory, so nothing
downloaded can ever be run. Termux stayed at `targetSdk` 28 for years over
exactly this, and lowering ours is not on the table — the three foreground
services are written against the typed model and `POST_NOTIFICATIONS`, all of
which is 33-and-later behaviour.

**proot gets past it by not exec'ing anything.** On intercepting `execve` it
substitutes its own loader for the program, and that loader maps the guest
binary and its ELF interpreter itself. Mapping is the permission W^X leaves
granted; exec is the one it takes away. The single file that really is exec'd is
the loader, and `get_loader_path()` reads `PROOT_LOADER` before anything else —
so shipping proot and its loader as `lib*.so` in the native library directory,
which is where "Bundled tools" above already puts executables, is the whole of
the fix. Nothing is patched to make that true.

**The distribution is Alpine, and one version of it.** `domain/rootfs.dart` is
the catalog, const data like the voice models. Alpine is 4 MB against Debian's
120, it is an official tarball rather than somebody's build of one, it is
`.tar.gz` where the alternatives are `.tar.xz` — which a phone's `tar` cannot
pipe and Dart decodes at a crawl — and `apk` is a package manager from the first
command. What it is not is glibc, so a prebuilt binary someone downloads may
refuse to run; a second entry here is what would answer that.

**The tarball's checksum is pinned and checked before anything is unpacked.**
Everything in there becomes a program this device will execute, so arriving is
not the same as being what was checked — the bargain `tool/bundle/versions.sh`
already makes for what is built into the APK. Bumping Alpine is a line in the
catalog.

**The system's `tar` unpacks it, not `package:archive`.** A rootfs is symlinks,
execute bits and the odd hard link — `/bin/ls` is a link to busybox, and a
busybox with no execute bit is a Linux that cannot run its first command — and
Dart can write none of the three, having no `chmod` at all. `tar -xzf` gets all
three right and is faster besides. It is injected into `FileRootfsStore` so a
test can watch what it was asked to do, and the real one is tried on `PATH`
before `/system/bin/tar`, the two-step `LocalShell` already takes to find a
shell.

Where it lives is `<cacheDir>/rootfs/`, outside the data directory, for the
reason the voice models are: `backup.dart` zips that directory whole, and a
restore *replaces* it. A `.complete` marker written last is the whole of what
"installed" means.

**The data directory is bound into the guest at its own path.** Not a tidier
`/workspace`: every path the app has ever handed the model — the chat's
workspace, the project's, an artifact — then means the same thing inside the
guest as outside it, the host `cwd` and proot's `-w` are the same string, and
nothing else in the app has to learn that commands are running somewhere else.
The workspace explorer, the `DocumentsProvider` and a resend of an old turn all
keep working with no knowledge of any of this.

**A `Sandbox` replaces the `Toolset` rather than layering over it.** Inside the
guest the bundled bionic git is the wrong answer and `GIT_EXEC_PATH` names a
host directory that is not there; `apk add git` is the right one. So the guest
gets the guest's `PATH` and nothing of the host's — and settings still win over
both, which is the rule that was already there.

**Which one commands run in is read per command**, through the same seam
`LocalShell` re-reads `environment` through, so installing a Linux or going back
to Android reaches the next command rather than the next launch. That is why
`platformSandbox` is synchronous and `RootfsStore` has a `directoryOfSync`: it
is asked before every command, and on this side of the app that is one `stat`.

**Android keeps no `/etc/resolv.conf`**, and a guest program reads nothing else
to find a resolver. So `BundledTools` writes one — from what `ConnectivityManager`
says the current network uses, which is the user's own DNS rather than a public
resolver picked here on their behalf, and the only reason the app asks for
`ACCESS_NETWORK_STATE`. It is written at every launch and bound over the guest's
copy, so it is one file whatever is installed and it follows the network the
device is actually on rather than the one it was on the day the rootfs was
downloaded. Android saying nothing writes nothing: a guest that cannot resolve a
name is honest, where a silent fallback to someone else's resolver is not.

The invocation itself is `data/local/proot.dart`, a pure function so that the
whole of what this feature does can be pinned by a test on a machine with no
Android on it. `--kill-on-exit` because a killed tracer otherwise leaves its
tracees running; `--link2symlink` because a package manager unpacks with hard
links and app storage may not have them; `-0` because `apk` wants to be root,
which is a lie told to the guest rather than a privilege — the process is still
the app's own uid to the kernel.

What it costs is worth knowing: proot is ptrace-based, so filesystem-heavy work
is noticeably slower than native, which is why `platformDescription` tells the
model so. What it does not cost is size — 300 KB an ABI, against git's 12 MB,
and the rootfs is downloaded rather than shipped.

Building it is `build.sh` again, beside git. proot is termux's fork rather than
proot-me's, for the Android work already in it, and its one dependency is
talloc, which is built **from `talloc.c` alone** against `talloc-config.h` —
the answers talloc's own build system would have worked out by running test
programs, which it cannot do when cross-compiling. That is why there is no waf
step here and why the result is one object file. Two adjustments to proot, and
only two: an `#include <string.h>` upstream leaves out, which clang now refuses
rather than warns about, and `PROOT_UNBUNDLE_LOADER`, which keeps the loader a
file of its own instead of one extracted to app storage and exec'd — the thing
that cannot work here.

#### Running a model on the device

A model downloaded here answers with no network and no account. It is
llama.cpp's own server, bundled in the APK, started when a model is picked and
bound to the loopback address — and **it reaches the agent as an ordinary
provider**, because what it speaks is the `/chat/completions` shape
`OpenAiClient` was already written for. So `LlmRegistry`, the model picker, a
chat's pinned model, `meta.json`, the projection and every tool the agent has
work unchanged, and nothing below the settings page knows a model is local.

That is what rules out the alternative, which was binding libllama through FFI
and skipping the process. A small model's idea of a tool call is a template's
worth of prose that has to be parsed back into an OpenAI call, and doing that
per model family is most of what llama.cpp's server *is*. Writing a second copy
of it in Dart, to save a subprocess on a device that is about to spend a
gigabyte of memory on weights, is the wrong trade.

The endpoint is composed by `llmEndpoints` rather than written into
`settings.json`: its base URL holds a port asked of the OS at launch, so a file
naming it would be stale by the next one. It goes **first** in the list, which
is what decides a collision — `localProviderId` is the app's name, and a
`settings.json` that happens to use it is shadowed rather than allowed to take
the model's own endpoint away from it. What is stored is the pick —
`localModelId`, `localModelDevice`, `localModelContext` — and `applyLocalModel`
is the one function that makes what is running agree with it. Two callers, far
apart: the settings page, where a model is picked, and `AppSession.start`, where
a pick from a previous run is honoured.

**The provider appears the moment a model is picked, not when it answers.**
Mapping a four-gigabyte model takes the better part of a minute, and a chat
pinned to it must not lose its model for that minute after every launch. So the
endpoint is in the list while it loads and `PendingLlmClient` — the same shape
as `GatedLlmClient` — waits for `whenReady` before the first request goes
through. **It rides on the endpoint rather than on the registry**: an
`LlmEndpoint` is a config and, where reaching it is not the ordinary thing, the
client to reach it with. The first version had the registry comparing a provider
id against a name it had to be told was reserved, which is a special case in the
one place that should know nothing about who its endpoints are — and one more
`==` arm for every endpoint that ever needs decorating. A turn sent at a loading model waits; a turn sent at a model that will
never load gets the server's own last words as an `LlmException`, which for a
model too large to fit is the only place that is said at all.

**Nothing loads a model on its own.** A pick is a gigabyte of the phone's memory
and minutes of its battery, so it is picked in settings and nowhere else — a
download does not load it, and a chat pinned to a model that is not loaded says
the provider is not configured rather than quietly starting one.

##### What the NPU actually is

The honest answer is narrower than the word. ggml has one NPU backend,
`ggml-hexagon`, and it is Qualcomm's Hexagon on Snapdragon with HTP v73 and
later — everything else a phone calls an NPU (MediaTek's APU, Samsung's, Google's
Tensor) has no backend in llama.cpp at all, and Android's own NNAPI, which
would have covered them, was deprecated in Android 15 and never had one either.
The rest of what can be offloaded is a GPU, through OpenCL on Adreno or Vulkan.

So the design does not name the NPU anywhere. `LlamaServer.devices` runs the
server with `--list-devices` and offers whatever it says it found; the settings
page labels each by the kind read off its name, and a phone with nothing is told
so rather than being offered a dropdown of one. Which backends a build carried
is the build's business and which of them find hardware is the phone's, and only
the binary knows both.

What the Hexagon backend does *not* need is a signature. It enables an unsigned
process domain itself on the DSP, so an ordinary APK can drive the NPU — the
thing that would otherwise have made this a Qualcomm-partners feature. What it
does need is Hexagon SDK 6.6 or later at **build** time, which is behind a
Qualcomm account and not redistributable, so CI builds without it and
`HEXAGON_SDK_ROOT` is what turns it on. Nothing else changes when it is there:
the backend arrives as two more `libggml-*.so` and is found the way the CPU's
is.

It also decides the catalog. The Hexagon backend repacks **Q4_0, Q8_0 and
MXFP4** and nothing else, so every entry in `local_model.dart` is Q4_0 — a
K-quant is a model that quietly runs on the CPU on the one device that has an
NPU to run it on.

##### Where it lives, and what it costs

The binaries are in the native library directory, and for the reason git and
proot are: it is the only place an app targeting a modern Android may execute a
file from. Here that directory is load-bearing twice over, because the DSP's own
half of the Hexagon backend is resolved out of it too — `ADSP_LIBRARY_PATH` is
set to the same string as `LD_LIBRARY_PATH`, whether or not this build carried a
Hexagon backend, since the answer is the same directory either way and a build
that grows one should not also have to grow a line here. `LD_LIBRARY_PATH` is
not optional: the server is exec'd by path with no rpath in it, so libllama and
the backends beside it are found through that and nothing else.

**arm64 only**, and that is a size decision. The server and its libraries are
about 18 MB stripped against git's 12, and three ABIs of it would put 56 MB into
the universal APK. Nothing is lost: a 32-bit phone cannot map a two-gigabyte
model at all, and x86_64 Android is an emulator. A build without it leaves
`LocalLlm.available` false, which is also what the desktops and the web get —
and there the settings page says so and points at Ollama and LM Studio, which
are two of the presets and a better answer than a second copy of llama.cpp
inside this app.

The weights go to `<cacheDir>/llm/<id>/model.gguf` with a `.complete` marker
written last, beside the voice models and a downloaded Linux and outside the
data directory for the same two reasons: `backup.dart` zips that directory whole
and a restore *replaces* it, so a model in there would be a gigabyte in every
export and a deletion on every restore.

`FileLocalModelStore` is `FileRootfsStore` without the unpacking, and what the
three of them share is now in `data/local/download.dart`: `fetchToFile` for one
file, and `downloadStream` for the install around it. What was copied three
times was not the part that differs but the part that is easy to get subtly
wrong — **cancelling is the listener going away**, so the half-written directory
has to be removed with nobody left to tell, and the client closed on all three
exits without adding to a controller that is already closed. `reportsFor` is the
other half: a report is a notification rebuilt through the platform channel, and
a two-gigabyte model at the megabyte granularity the voice models were written
for is two thousand of them, most arriving faster than Android will draw.

**One hold, not three.** All three catalogs fetch into a single platform slot,
and `downloading(null)` stops the foreground service outright — so a
four-megabyte rootfs finishing while a model is still streaming would drop the
hold and leave the app killable in the middle of the longest download it makes.
`DownloadHold` is the only caller of `BackgroundWork.downloading` and merges what
each source reports, which makes that unrepresentable rather than a rule three
notifiers have to keep.

`-c` is the setting that decides whether Android kills the app, and it defaults
far below what any of these models was trained for. The weights are mapped and
paged; the KV cache is not.

**The server is bound to 127.0.0.1 and given a key generated per launch.** Every
app on the device can reach the loopback address, so without one any of them
could spend this model's battery. The key is never written down — it lives in
the running `LlamaServer` and in the provider config it hands the registry, and
both go when the server does.

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

`ApprovalBanner` shows **the call, not the tool**. It named the tool and put the
arguments JSON under it at two lines and an ellipsis, which is a consent dialog
asking to be waved through: what is being agreed to is the command, and the
command was the half that got cut. It sits in mono on a plain surface inside the
tinted banner, capped at `ApprovalBanner.mostHeight` and scrolling past it, so a
command of any length is readable without the banner burying the conversation it
is asking about.

What it shows is `ToolApproval.argumentsText`, which is the field `ToolCall`
already carried and is now on both. The banner does not parse: `_bash` has the
command in a local and `_webfetch` has the URL, both one line above the
`_runGated` call that raises the approval, so the wording rides with it. Digging
it back out of the JSON in the widget was the first version, and it meant a list
of argument names — `command`, `url` — kept in a widget file, describing tools
it is nowhere near. The raw JSON stays as the fallback for a tool that words
nothing, which is what `ToolLabel` does with the same field.

It is its own file rather than the end of `message_bubble.dart`, where it used
to live: it is not a message, and the turn is what is asking.

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
stop button, which is why the panel carries the only way out of it. The rest
mirrors approvals exactly: turn-scoped view state, `_clearQuestions` beside
`_clearApprovals` so an abandoned turn answers its own questions, the completer
created when the event is forwarded rather than when it is awaited.

**Nothing is sent until the user says so.** Picking the last option used to
submit the batch, which made the panel a form with no review: an answer given
two questions ago could only be reached by pressing Back through the ones after
it, and reaching it at all was impossible once the last one was picked, because
picking it was the send. `_Segments` is the fix and the whole of the
navigation — one bar per question, tappable, so any of them is one press away.
Which one you are on and which have been answered are on two channels, height
and colour, so neither is read out of the other.

There is **one button, because there is one action**: send what has been picked.
It reads `Skip` while nothing has been and `Send` after, since those are the two
things the same action amounts to. Two buttons would be two promises, and the
turn cannot be left any other way — `askAnswers` already words an empty set for
the model.

Picking still moves on to the next question, which is the fast path through a
batch; it stops at the last rather than submitting there. Back and Next go dead
at the ends rather than wrapping, the way the thread arrows under a message do
— and asked one question, none of that is drawn at all: `Question 1 of 1` over
a single segment with two arrows that can only be dead is the `1/1` the thread
counter leaves out, for the same reason.

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

**Three services, not one.** `VoiceService` holds the microphone while voice
mode is listening and `DownloadService` holds a model being fetched, and both
are as much work the process must not be killed in the middle of as a turn is.
They are separate because a service has one foreground notification and these
are three different things to stop — and because from Android 14 the one that
holds the microphone has to say so, hold `RECORD_AUDIO`, and be started while
the app is in use, none of which a `dataSync` service may claim. Everything
about *how* a service is held, stopped, refused and woken is `ForegroundWork`;
each of the three says only which it is and what its notification reads.
`BackgroundWork` therefore carries a kind rather than a count, and
`stopRequests` says which button was pressed — killing every turn because a
download was cancelled is not what the user pressed. The wording stays in Kotlin
for the first two; a download's cannot, since which model is being fetched is
the catalog's and Kotlin has never heard of the catalog.

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
finishing and `ForegroundWork.busy` is false — which counts voice mode too,
since the session it holds is in that same isolate. Cached unconditionally it would be a
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

**Only the prompt is a bubble.** A reply is drawn full width with nothing tinted
behind it — it is the page rather than something said to one side of it — and a
prompt keeps its container, capped at four fifths of the line and pushed right.
That cap reads the constraints it is given rather than the window, since the
conversation is a centred column on a monitor and the window is no longer what
the message has to fit in. Which of the two a role gets is the null in the
`(name, bg)` switch, so there is one place that decides.

**It has no name over it either**, which is the other null in that same pair.
Nothing else in a conversation is drawn full width and unbubbled, so
"Assistant" over every reply was the layout said a second time, once per turn,
all the way down the page. The other three keep theirs: a name is what makes a
prompt something said and a tool run something reported, and neither of those
is the page.

While a reply is still being written it ends in a `StreamingCaret`, which is
the other half of what the spinner does — the spinner answers for a turn that
has said nothing yet, the caret for one that has. It goes on the last text part
**only when that part is the last part of the message**: text with a tool call
under it stopped arriving before the call started, so a caret left there points
at nothing while the label below is what is actually busy. It is a `WidgetSpan`
so that it sits after the last word rather than under the paragraph.

**Never both**, and that is one decision in `_rows` rather than two that happen
to agree. Asked separately they did not: the spinner's question was
`Message.hasText`, which trims, so a turn whose first flush was a blank line had
said nothing by that test while its last part was already a `TextPart` — a
spinner and a caret at once. `liveAt` is the same consolidation a level down,
since "the part this turn is working on" was being spelled out for the caret and
again, with a clause on the end, for `ThinkingLabel.isLive`.

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

A run of two or more non-important activity labels collapses behind a single
centered "Expand activities" toggle (`ActivityGroup`), default collapsed. What
is important and so stays visible, breaking a run: an artifact button, a failed
tool run, an `ask_user` question, and the live label a running turn is working
on. Text, errors and files are not labels and break a run too. A lone label is
left where it is — a toggle for one label is noise. The decision is per-part in
`_rows` (buffer into a pending run, flush at any break), and the length check
lives at flush time so a run is never half-collapsed. State is per-run and
in-memory: `ValueKey`ed on the run's first part index so a per-delta rebuild
keeps the same expanded/collapsed state, but a reload starts collapsed the way
every fresh view does.

The drawer is sized by what is in it, up to the whole screen. It used to stop at
seven tenths of the height, which is a tool's output cut short and a third of the
screen left empty under it. It is a route, so the back key closes it and nothing
had to be written for that.

#### Selecting a reply, and copying it

The **message** is one `SelectionArea` and the markdown inside it is not
selectable of its own accord. `MarkdownBody(selectable: true)` builds a
`SelectableText` per element, and each of those is a selection region to itself
— so a drag stopped at the paragraph it started in, which is the whole
complaint. Plain `Text.rich` under one region selects across the lot.

The region is around all of `_rows` rather than inside `_bubble`, and that is
the whole point rather than a detail: `_rows` closes the bubble at every
reasoning part and every tool call, so a region per bubble would have stopped
the drag at the first tool label — which is most of the replies this app makes.
It also cost a `SelectableRegion` per bubble on every streamed delta, since a
message is one list item and rebuilds whole.

What that puts inside the region is the labels, which are not what the message
said, so each is wrapped in `SelectionContainer.disabled` — dragging past one
must not put "Thought for 12 seconds" on the clipboard. The `SelectableText` in
a label's drawer is on its own route, so nothing nests.

What a selection copies is the **markdown that was rendered**, not the text it
rendered to: `_MarkdownSource` is a `SelectionContainer` delegate per text part
that answers `getSelectedContent` with the part's source. There is no finer
granularity available — the renderer keeps no source offsets, so there is
nothing to map a partial selection back through — so anything selected inside a
part copies the whole of that part. That is what puts `**bold**` on the
clipboard rather than `bold`, and it is why the copy button below is the same
answer at message scale rather than a second mechanism. The delegate answers
from `value.hasSelection` rather than from `super.getSelectedContent()`, which
would walk every selectable and concatenate what each holds only for the answer
to be thrown away.

What can be done to a message is a row under it rather than a menu, uncovered by
hovering the message or, where there is no pointer to hover with, by touching
it. Left to right: which thread this is and the arrows between them, copy,
delete, then Edit and Regenerate. Copy takes the message's `plainText`, which is
every text part and no thinking — the same rule a rewound session is seeded by.
It is offered only where something was said, since a message of tool calls alone
would copy nothing. The counter and the arrows are there only where there
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
gesture arena, so one touch both starts a selection in the bubble and shows the
actions. It writes a `ValueNotifier` rather than calling `setState`, so
uncovering the icons does not rebuild the message's labels behind them.

#### How a reply is set

`replyStyleSheet` is the whole of it, and it starts from
`MarkdownStyleSheet.fromTheme` because most of what that answers is right. What
gets overridden is where the defaults were written for a document rather than a
chat, or where they read a Material 2 field that M3 leaves null.

The null-reading ones are bugs rather than taste. Inline `code` asks for
`cardTheme.color`, which is null here, so a `` `word` `` in a sentence was that
word in another face and nothing else. It sits on a surface now. A
`backgroundColor` paints tight to the glyphs with no room either side, which is
not as good as the padded container a block gets — but a block is one thing on a
line of its own, while inline code has to wrap with the sentence, and a
`WidgetSpan` cannot break across lines.

The document-shaped ones are the headings and the rule. `fromTheme` gives h1
`headlineSmall` and h4 down `bodyLarge`, which is body size carrying no weight,
so the bottom three levels did not read as headings at all; they now step 21,
18, 16 and then sit at the body size with weight to tell them apart. Every level
is given room **above** and none below, since a heading belongs to the paragraph
it introduces — the default is `EdgeInsets.zero` everywhere, which put a heading
against the paragraph before it. And a horizontal rule was five pixels of
`dividerColor`, which is a slab across the page rather than a rule.

Prose is set looser than Material's 1.43, since a reply is read as prose in a
column where the line you want next is the one below. That goes to `p`,
`listBullet`, `blockquote` and `tableBody` rather than to `p` alone — the rule
is about the reply, not about the `<p>` element, and `fromTheme` hands all four
the same plain `bodyMedium`. A list is the shape a reply most often takes.

**Code is set in a bundled face**, and `ui/fonts.dart` is the whole of what
Dart knows about it. `monospace` is an alias the platform resolves, so the same
reply was Roboto Mono on one Android, Droid Sans Mono on another, DejaVu on
this desktop and whatever a browser prefers on the web — and the five things
this app shows verbatim (code, a tool's command and its output, a chat id, a
config value) are shown that way precisely because their characters line up.
Roboto Mono is the mono companion to the face Material already uses.

`monoFamily` and `registerBundledFontLicences` are in a file of their own
rather than in `ui/theme.dart`, which owns the palette and could not read an
asset if it wanted to. Five facts have to move together — the `family` and the
two `.ttf` entries in pubspec's `fonts:` block, the `OFL.txt` asset, and those
two — so they are one file and one section here rather than scattered by
proximity.

**Both faces are subset to Latin.** Text fonts are not tree-shaken the way icon
fonts are, so the full files shipped 876 codepoints of which nearly half were
Cyrillic, Greek and Latin-Extended — and on the web the engine blocks the first
frame on every font in the manifest, so that was 148 KB gzipped before anything
painted. Subset it is 58 KB. Anything outside the subset falls back to a system
face, which is what already happened to arrows and box-drawing: Roboto Mono has
never had them. Regenerating, which nothing automates:

```sh
uv tool run --from fonttools pyftsubset RobotoMono-Regular.ttf \
  --output-file=assets/fonts/RobotoMono-Regular.ttf --layout-features='*' \
  --name-IDs='*' \
  --unicodes="U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,\
U+2000-206F,U+2070-209F,U+20A0-20BF,U+2100-214F,U+2190-21FF,U+2200-22FF,\
U+2500-257F,U+2580-259F,U+25A0-25FF,U+2713-2717,U+FFFD"
```

`--name-IDs='*'` is not decoration: it keeps the copyright and licence records
in the file, which is half of what the OFL asks for. The other half is
`assets/fonts/OFL.txt`, an asset rather than only a file in the repo, read into
`LicenseRegistry` lazily — so Flutter's own licence page has it whether or not
this app grows one. Bold is bundled beside regular because inline code inherits
the weight of what holds it, and a heading with a `` `name` `` in it is a shape
this app's replies take constantly.

#### Code blocks

A fenced block is `code_block.dart`'s: a bar naming what it was fenced as with
a button that copies it, and the code highlighted underneath, scrolling
sideways rather than wrapping — a wrapped line is no longer the code that was
written.

It is a `MarkdownElementBuilder` for `pre` rather than
`MarkdownBody.syntaxHighlighter`, which is handed the code and nothing else.
The language is not in the code: the parser puts the fence's info string on the
`code` element inside the `pre` as `language-<name>`, so only something holding
the element can read it. The copy button needs somewhere of its own to sit
besides.

Highlighting happens **while the markdown is parsed**, not while the block is
drawn. `MarkdownBody` builds its widgets once per `data` or style sheet change
and keeps them, so a builder that returns a finished `TextSpan` runs a grammar
once per parse, where a `CodeBlock` that highlighted in `build` would run one
per scroll frame.

That is not once per block, though, which is why the spans are also **kept**.
A parse happens whenever the style sheet changes, and a palette change lerps
`ThemeData` across every frame of a cross-fade — so switching to dark re-runs
every grammar on screen a dozen times over, and scrolling a block out of the
list and back rebuilds it from nothing. The cache is keyed on the code, the
language, the style and the brightness, and bounded at sixteen entries evicted
oldest-first: what it holds is the text of every block in it, so one that grew
with the conversation would be a second copy of the chat in a process that
already has one.

`re_highlight` is highlight.js's grammars and themes in pure Dart, which is the
whole reason it is the one here: the alternative with the more recent commits,
`syntax_highlight`, pulls `super_clipboard` and so a Rust toolchain into the
build of an app whose claim is that there is nothing to install.
**Thirty-one grammars are registered rather than all 197.** A grammar is data
and nothing tree-shakes an unnamed one, so all of them cost 359 KB gzipped in
the web bundle against 56 KB for these — measured, both. A fence naming
anything else is drawn plain, which is what every fence did before this
existed, so the cost of an omission is the behaviour it replaces and nothing
worse. That is also the answer for a grammar that throws or breaks off
part-way: the partial render would be *less* code than was written, and half a
command is worse than an uncoloured whole one.

The token colours are github and github-dark, picked by the palette. What is
dropped from each is its `root` entry — the one thing in a highlight theme that
is not a token colour. The surface comes from the app's own scheme instead, so
a block belongs to the page it is on rather than to highlight.js, and dark mode
does not have to be told about it twice. `codeblockDecoration` is where that
surface goes rather than the block itself, because `pre` is wrapped in the
style sheet's decoration whether or not a builder drew what is inside; the
default is `cardColor`, which M3 resolves to `colorScheme.surface`, and a code
block the colour of the page is why this was worth doing at all.

The bar is `SelectionContainer.disabled`, the same rule the labels above the
bubble keep: a drag across the reply copies the markdown behind it, and the
language name is not something the model said. Its copy button is `ActionIcon`
and reports through `copyToClipboard`, which is the same button and the same
snack bar the row under a message uses — the other idiom, an icon that turns
into a tick for a second, is a second answer to one event and a timer for this
widget to own.

`codeblockDecoration` is the **only** thing the style sheet still decides about
a `pre`. Registering a builder for it makes the package's own `visitText` arm
unreachable, and `codeblockPadding` is read nowhere else, so setting it would
be configuring a path that no longer runs. The font is the exception in the
other direction: the sheet's inline `code` and the block are both built on
`codeFont`, so the bundled face reaches the two of them rather than one.

### The chat page

One app bar, whichever layout it is drawn in. Narrow, the sidebar is `ChatPage`'s
own drawer rather than a shell's — two bars stacked was the app's name over the
chat's, saying nothing twice. **It names the chat, always**: the title, the
project, and the pin or the countdown. It followed the scroll position at
first — the mark and "Entoli" at the top of the list, the title once past it —
and that put the app's name where the chat's belongs for every conversation
short enough not to scroll, which is most of the ones being started. The mark is
still on the bar with no chat open, where there is no title to draw instead.

**The bar grows with what it has to say.** One detail line fits under the title
in Material's 56dp toolbar and two do not, so a chat that is both in a project
and temporary was having its countdown clipped. The lines are counted rather
than measured — a bar that sized itself to its text would have to lay the text
out to know its own height, and a `Scaffold`'s `appBar` has to answer that
before it is built — which makes the count a thing that can drift from what is
drawn. So it is not a second list of conditions: `_details` is the only place
they are written down and `_barHeight` counts what it returned. The per-line
number is `_TitleLine.height` and the row is *held* to it rather than measured
against it, so what the bar adds for a line is what the line takes, at any text
scale.

The conversation is a column of `_readableWidth`, centred. A phone gets the
whole screen and a monitor gets a line that can be read back to the start of.
The composer is inside that column rather than under it: a centred conversation
over a full-width field is a field twice the width of what it is answering.

With nothing selected the pane is the ways to have a conversation — New Chat,
New Voice Chat and Open Chat — over the project they happen in. The second is
an extension of the first rather than a third thing: it makes a chat and opens
it in voice mode, and it sits with New Chat rather than beside the way to open
an old one. Open Chat is the drawer, so it
is drawn only where there is one: beside a sidebar that is already out it would
open what is on screen. It asks the `Scaffold` above it rather than taking a
flag beside the one that built that Scaffold, since two answers to "is there a
drawer here" can disagree. New Chat is `startChat`, which the sidebar's own
button also calls, so there is one answer to what a new chat is and which
project it lands in.

Above them are the projects, as badges, and that is the same discovery
`_EmptyChat` does for commands: the switcher at the top of the sidebar is the
only place a project is named, and the sidebar is what this pane is drawn
instead of. Picking one is `selectProject` — the switcher's own action, lifted
out of `_ProjectMenu` so that nothing that switches projects can come to
disagree about what switching means. Deleting one goes through it too. **The
badge is where the project changes, not either button**: New Chat and Open Chat
act on what is already picked out, so pressing one is never also a choice about
where it lands.

**The default project is nothing selected**, and so has no badge. It is not a
project beside the others — it is the absence of one, which is what `null`
already means everywhere else it is written down. A `Default` badge would say
otherwise, and would be a thing to press to get back to where the app opens.
Pressing the selected badge is that instead, which makes the row a set of
toggles rather than a set with one always down.

So a user who has never made a project sees nothing here, which is right: with
none there is no choice to offer, and the row would be one badge that is always
selected and can lead nowhere.

A chat with nothing *said* in it is `_EmptyChat`, and it is a different question
— the chat is open, so what is missing is the first thing to say. It draws the
mark, the question, and a chip per `/command` and `@agent` the library holds.
That list is the point of it: the composer's menus are the only place those are
named, and nothing names them until the character that opens one has been typed,
so a user who does not know they exist never finds out. Six at most, because
everything the user has written is a menu and `/` is what opens the menu; with
nothing at all in the library it says how to reach them instead.

Tapping one types it into the composer through `insertCompletion`, which is the
composer's own insertion lifted out of its `State` so both callers reach it.
Both halves of that mattered. **Where** it lands is a rule: a command goes to
offset 0, because `BuiltinBackend._command` is anchored there and
`activeCompletionToken` gates `/` on `start == 0` — appended at the caret it
would be text that looks like a command, dispatches as none, and is not even
offered a menu. A mention goes at the caret, since `_mention` reads one wherever
a word starts. And it **does not ask for the focus**, which is the composer's
other rule — see "The keyboard and the caret": on Android focus is the keyboard,
and a chip that raises one over a conversation nobody was typing in is exactly
what that rule exists to stop.

`NavDrawer` is that drawer, and the only thing it says is a width: below
Material's compact breakpoint it takes the whole screen, since 304dp of panel on
a phone leaves a strip of chat nobody can read and nothing else. A width rather
than a platform check, which is how every other question of room is answered
here — `navBreakpoint` above it, the bubble's share of the line below. It is
shared with the settings page's categories, which is worth it for the back key
alone: the paragraphs below are what a second copy would have to get right.

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

A chat opens at its latest message. `_settleAtBottom` jumps and then jumps
again until the extent stops moving: a builder lays out only what shows, so the
extent any one frame reports is an estimate and a single jump lands short of the
end. **Jump to latest goes through it too**, after its animation — the extent it
read when the button was pressed was that same estimate, so on its own the
button left the reader a little above the last message, by an amount that
depended on how tall the messages happened to be. Not
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

### Voice mode

A circle for what the microphone hears and five scrolling lines of what has
been said, over a chat that was already open. Everything runs on the device,
and which device decides how: **the desktops run `sherpa_onnx`** — speech
recognition, speech synthesis and voice activity detection from one dependency,
with the models downloaded from the settings page rather than shipped — while
**Android runs the system's own engines** and has no models at all. See "The
Android system engines", which is also where the reasoning for that split is.

**A voice turn is an ordinary turn, and that is the constraint the rest is
written to keep.** `VoiceController` hands what it heard to
`ChatController.send` and reads the reply back out of the chat: same
`TurnSettings`, same model, same approve mode, same tools — `bash`, `task`,
`ask_user`, the lot — and the same records in `conv.jsonl`, so threads, resume
and rewind all work on a conversation that was spoken. Nothing in the backend
knows voice mode exists. Leaving it leaves a chat to read, and a chat being read
can be carried on out loud.

So `VoicePage` is a *view*, and its job is surfacing what a turn already does in
a shape you can use without looking. The approval banner, the question panel and
the sub-agent strip are **the same widgets** drawn here too, rather than reduced
voice-only versions: a turn waiting on an answer nobody can see is a hung turn,
and a second copy of either is a second thing to keep right.

The port is `Voice`, behind the app's one conditional import like `Shell` and
`WebSearch`. `Voice.available` is false in a browser, which is what leaves the
composer's circle undrawn — see issue #58 for why sherpa's WebAssembly is not
the answer there, and what is.

**It is kept out of the Android build too, and that one is measured in tens of
megabytes.** onnxruntime and sherpa's own library are about 26 MB per ABI,
uncompressed and page-aligned the way a modern APK stores native code: 75 MB
across the three, which took the universal release APK from 64.5 MB to 141 MB —
more than the rest of the app put together. With Android on the system engines
there is nothing left to load them, so they are excluded at packaging in
`android/app/build.gradle.kts` and the APK is back to 64.5 MB, measured.

**Excluded rather than removed, because they are not ours to remove.**
`sherpa_onnx` declares all ten of its per-platform packages in its own pubspec —
four Android ABIs, iOS, Linux, macOS, Windows, web — and pub resolves what a
package asks for. `dependency_overrides` is the only other lever and it replaces
a package on *every* platform, which is a risk worth taking once (below) and not
four more times. A `packaging { jniLibs { excludes } }` block drops the `.so`
files where they are actually unwanted and leaves every other platform's alone.
Vendoring the desktop libraries into `linux/CMakeLists.txt` instead would mean
dropping `package:sherpa_onnx` and writing the FFI bindings by hand — and
`sherpa_onnx_linux` already delivers those libraries through pub, so there is no
gap there to fill.

The one thing to know is that the exclusion and `platformVoice` have to agree:
the `.so` files are gone from Android, so a `SherpaVoice` constructed there
would fail at its first FFI call rather than degrade. `platformVoice` returns
`AndroidVoice` on that platform and nothing else builds one.

Keeping it off the web takes one deliberate piece of machinery.
**`sherpa_onnx` depends on `sherpa_onnx_web` whatever platform is being built**,
and that package declares a 14 MB WebAssembly build of onnxruntime as a
web-platform asset. Plugin assets are not tree-shaken, so simply adding the
dependency put 14 MB into a build that can never call it — measured: the web
build went from 43 MB to 58 MB. `tool/sherpa_onnx_web_stub` is a local package
of the same name, overridden in `dependency_overrides`, holding the two members
the web plugin registrant reaches for and no assets at all. Nothing on the web
imports `package:sherpa_onnx`, so none of the real API is ever wanted.

The trap in it is that a `dependency_overrides` entry replaces the package on
**every** platform, not only the one it was written for. If a `sherpa_onnx`
bump inside `^1.13.6` ever reaches a third member of `SherpaOnnxWeb`, the
desktop and Android builds break for a web-only reason — so the stub is
something to check when that constraint moves, which the espeak-ng note above
means it eventually will. The
Silero asset is kept out the ordinary way, with `platforms:` on its pubspec
entry.

#### What listens and what speaks

`domain/voice_model.dart` is the catalog, as const data: five recognition models
and three speech ones, each naming its files, what it costs to fetch, and which
sherpa family runs it, and the two Android-system sentinels beside them. A model
Entoli can run is one someone wired an engine for, so a new entry is a line
there and a case in `sherpa_voice.dart`.

Recognition models are fetched **file by file** from HuggingFace — two to four
each — which skips the fp32 copies the release tarballs carry beside the int8
ones: the SenseVoice tarball is 999 MB for a 228 MB model. Speech models arrive
as the official `.tar.bz2` and are unpacked, because each carries
`espeak-ng-data`, some 360 files that are not worth fetching one at a time. bz2
in Dart runs at about 8 MB/s, so Kokoro spends a visible minute unpacking and
the progress bar has an "Unpacking" phase of its own; the work is in an isolate
so the bar can keep moving. `dart:io`'s native gzip would be twenty times
faster, and upstream publishes no `.tar.gz`.

**Kokoro is the only multilingual speech model there is at this size**, and it
is worth writing down why the list looks thin. Piper covers thirty languages one
model at a time, which is a language picker rather than a multilingual model;
MMS covers a thousand at rough quality and one model each; everything genuinely
multilingual beyond them is far too big for a phone. Whisper hears 99 languages
and Kokoro answers in two, and the honest fix for a third is one more const
entry.

Silero's detector is the exception that ships: 644 KB, an asset rather than a
catalog entry, because voice mode that cannot start until a second and invisible
download has finished is worse to explain than an app that is slightly bigger.
Every model sherpa takes it takes as a path, so it is copied out of the bundle
on first use. Its MIT licence is an asset too, read into `LicenseRegistry` the
way the font's OFL is.

**sherpa-onnx vendors espeak-ng, which is GPL-3.0.** Entoli is AGPL-3.0, so that
is fine — it would not be for a permissively licensed app, and it is the sort of
thing that is invisible until it is a problem. Upstream is removing espeak in
2.0, which will want lexicon-based models instead; the constraint is pinned at
`^1.13.6` until then.

#### The Android system engines

A phone already has a speech recognizer and a speech synthesiser, and until this
landed voice mode ignored both and asked for a download first. So on Android
voice mode **is** the OS: `TextToSpeech` and `SpeechRecognizer` behind the
`agent_chat/voice` channel, with nothing to fetch — and sherpa-onnx is not built
into that platform at all.

**Why sherpa went rather than sitting beside them.** It ran on the CPU, and
there was no way to change that: the `libonnxruntime.so` in the pub package
exports exactly two execution-provider factories, `..._CPU` and `..._Nnapi`
(checked with `nm -D`), XNNPACK and QNN are named in its strings but have no
code in the build, and ONNX Runtime has no Vulkan, OpenCL or GPU provider for
Android at all. NNAPI is the only accelerator route and it is a bad one —
deprecated in Android 15, frequently *slower* than ORT's own kernels because
unsupported ops fall back to `nnapi-reference`, and it crashes outright on VITS
TTS (k2-fsa/sherpa-onnx#2443). So keeping it meant 75 MB of native code for the
slower of the two answers, on the one platform where battery is the constraint.

**What that costs is a phone with no system engine**, which is a real device
rather than a hypothetical: `SpeechRecognizer` needs a recognition service and
`TextToSpeech` needs an engine, and a de-Googled phone may have neither. Both
are ordinary apps that register with the platform, so the fix is an install
rather than a build — RHVoice or eSpeak NG for speaking, FUTO Voice Input for
hearing. `_MissingEngines` in `voice_settings.dart` is that said on the page,
with the links, because an empty picker on a platform with no catalog behind it
is otherwise a dead end that gives no sign of being one install away. Nothing
has to be told when one arrives: the next launch asks the device again.

The desktops keep sherpa, and there the reasoning does not apply — they have no
system engine to ask, and no battery argument of the same kind.

**They are catalog entries rather than a mode.** `android-recognition` and
`android-speech` are a `RecognitionModel` and a `SpeechModel` with no downloads,
in `voiceCatalog` but not in `recognitionModels`/`speechModels`. That is what
makes them cost nothing: every gate the app already has — `voiceReadyProvider`,
`speechReadyProvider`, the settings dropdowns, `ReadAloud`, `VoiceController` —
resolves a pick through `voiceModelOf` and asks whether it is installed, and a
sentinel answers both questions without any of them learning a new shape. A
`nativeVoice` flag beside the model id would have been a second thing every one
of those had to consult, and the one that forgot would be wrong silently.

`VoiceModel.isNative` is the whole of the routing, and it reads `engine` — the
field that already decides what runs a model, rather than a second id constant
beside it. `AndroidVoice.start` refuses anything else.
`Voice.downloadsModels` is the other half: false on Android, which is what takes
the catalog off the settings page, and it has exactly that one reader.

**What decides is whether the engine is there, not whether this is Android**,
and the answer goes into the set that already existed for the question.
`Voice.systemEngines()` asks the device — `SpeechRecognizer` needs a recognition
service installed and `TextToSpeech` needs an engine, and a phone with no Google
apps on it may have neither — and `main` folds what it says into
`installedVoiceModelsProvider` beside the models on disk. So a sentinel is
usable on exactly the terms a downloaded model is, and every gate is the
`installed.contains(...)` it already was: the ready providers, the settings
dropdown, the defaulting. "Is this Android" was the first version and it was
wrong on a real phone; a `nativeVoiceEnginesProvider` beside the installed set
was the second, and it was the thing this section's own rule warns about — a
second question each gate had to remember, silently wrong in the one that
forgot.

It is on `Voice` rather than in `core/platform/` because that port is already
per-platform and already built there, which keeps `io/platform.dart` resolving
`Platform.isAndroid` once instead of twice and leaves `platform.dart` with no
member exposed any way but its own. `FakeVoice` is then the test seam, so
`TestApp.create` takes `nativeVoice` and nothing parallel has to be overridden.

So **each side is defaulted on its own**. A phone with a synthesiser and no
recognition service gets the speaking half and leaves the listening half
unpicked, which is the honest answer: read-aloud works, the composer's voice
button stays away. A sentinel pinned by hand or carried in a `settings.json` is
refused by the same set, so it needs no rule of its own.

The default is filled in `AppSettingsNotifier.build` and **not written to
disk**. A file that names something is left as it is; only a null is read as
"the system one". Saved, it would be a pick the user never made, following their
data to a machine where it means nothing — and it would take the ability to say
"no pick yet" away from the platforms that have an answer for it.

The probe needs the manifest's `<queries>` block, and that is the trap in it:
from Android 11 an app sees only the packages it declares an interest in, and
both `isRecognitionAvailable` and the TTS service query are answered out of that
view. Without it they report nothing on every modern phone rather than only on
the ones that genuinely have nothing — which is a default that quietly stops
working, in the direction that looks like a device problem.


##### Per side, not per session

`SherpaVoice` used to be one class holding a microphone, two workers and a play
queue, and a native engine could not be half of that. So listening and speaking
are `Listener` and `Speaker` in `voice_strategies.dart`, and
`ComposedVoiceSession` holds one of each and wires them together. Neither half
knows which the other is.

The split was built to let the two kinds mix per side, which no platform now
does — Android is native on both and the desktops are sherpa on both. It earns
its keep anyway, twice: `AndroidVoice` is a dozen lines because the session, the
barge-in wiring and the silence reporting were already somewhere neither engine
owned, and `read_aloud` gets a speak-only session by passing a null [Listener]
rather than by either engine knowing what reading one message out is.

`Speaker.speaking` is on the interface for one reason, and it is the reason the
split needed care: voice activity opens **every** utterance, not only the ones
landing on top of a reply, and `VoiceController` aborts the running turn on a
`VoiceInterrupted`. So the session forwards one only while something is actually
being said. That guard was inside the old single class as `_playing ||
_queue.isNotEmpty`, where it read as an optimisation; on the interface it is the
contract, and each speaker answers it its own way — the sherpa one from its
queue, the native one from what `TextToSpeech` has been handed and not reported
done.

##### The Kotlin

`VoiceChannel.kt`, registered on the cached engine against the application
context like the other three — the engine outlives the activity. Three things
about it are not obvious:

**`SpeechRecognizer` hears one utterance and stops.** Continuous listening is a
`wantListening` flag and a restart from `onResults`/`onError`, posted rather
than called where it happens: the old recognition is still running inside the
callback, and starting the next one there is what `ERROR_RECOGNIZER_BUSY` is.

**Silence is not a fault.** A room with nobody talking in it produces
`ERROR_NO_MATCH` or `ERROR_SPEECH_TIMEOUT` every few seconds, so those restart
without a word; reporting them would leave voice mode in the failed state for
the ordinary case of waiting to be spoken to. `ERROR_INSUFFICIENT_PERMISSIONS`
is the one that stops.

**`TextToSpeech` answers on a binder thread**, and a `MethodChannel` may only be
touched from the main one. Everything Dart hears goes through `send`, which
posts. Invoked where it happened it would be a crash in the one path nothing on
a desktop exercises.

`AndroidVoiceBridge` is the Dart mirror of the same constraint from the other
end: `setMethodCallHandler` takes one handler and two strategies each setting
one would leave the second overwriting the first, so the bridge owns the handler
and the strategies register callbacks on it.

No new permissions — `RECORD_AUDIO` was already declared and the synthesiser and
recognizer need none. The **grant** is a different matter: `SpeechRecognizer`
reports the lack of one as an error rather than asking, and nothing else on the
native path would ask at all. `SherpaVoice.start` asks for both kinds of
listener through `AudioRecorder.hasPermission`, which is the only thing in the
app that can, and the native branch throws the recorder away again.

`VoiceService` is untouched. The microphone still needs holding for as long as
voice mode is listening; only the engine behind it changed.

#### Where the models live

`<cacheDir>/models/{stt,tts}/<id>/`, and **outside the data directory** for a
reason bigger than tidiness: `backup.dart` zips that directory whole, so a
Kokoro and a Whisper base in it would put three hundred megabytes of
bytes-you-can-fetch-again into every export — and a restore, which *replaces*
the data directory, would drag them between machines and wipe whatever was
already downloaded. Outside it, both are true by construction rather than by a
rule in `writeBackup` that someone has to remember.

A downloaded Linux is beside them, at `<cacheDir>/rootfs/<id>/`, and it is there
for exactly the same two reasons — see "A whole Linux under proot".

`platformCacheDir` resolves it by hand, the way `platformDataDir` does:
`$XDG_CACHE_HOME/agent-chat` or `~/.cache/agent-chat` on Linux,
`~/Library/Caches/agent-chat` on macOS, `%LOCALAPPDATA%\agent-chat\Cache` on
Windows, and `$AGENT_CHAT_CACHE` over any of them.

**Android is the one place "cache" is the wrong word.** `getCacheDir()` is
evictable — the system empties it under storage pressure and the app's settings
offer a Clear Cache button that does the same — and a 140 MB model the user
deliberately downloaded must not go that way. `FilesChannel` already stages
shares in `cacheDir`, where losing a copy is harmless; this is not that. So
Android uses the support directory, a sibling of the `app_flutter` tree the data
directory lives under: outside the backup, and not thrown away.

A `.complete` marker is written last in each model's directory, and it is the
whole of what "installed" means — the same trick `turnEnd` plays in
`conv.jsonl`. `installed()` reads the directories rather than the catalog, so a
model the catalog has since renamed still shows as taking up the space it takes
up. Cancelling a download cancels the subscription, and the store deletes the
half-written directory when its listener goes.

#### Hearing and speaking

`SherpaVoice.start` loads the two models and opens the microphone; what comes
back is a `VoiceSession`, which is where **two worker isolates** live. sherpa's
calls block, so on the UI isolate a Whisper encode is a frozen screen. They are
two rather than one because generating a spoken sentence takes about a second,
and a single worker would have the microphone's frames queued behind it — which
is exactly when the user is most likely to talk over the reply, and exactly the
moment the detector would be deaf.

Audio in is `record` at 16 kHz mono PCM, chunked to Silero's 512-sample window
before it is handed over. `Pcm16Reader` is what does the chunking, and it is a
class of its own because both things it gets right are invisible: a chunk is a
*view* into the buffer the platform channel decoded into, starting at byte 5 of
it on Android, and `asInt16List` refuses an odd offset outright — every frame of
every session threw, so voice mode listened to nothing at all. The other is that
a chunk does not have to end on a sample, and a byte dropped there shifts every
sample after it. Audio out is `audioplayers` over a WAV written per
sentence, into the system's temporary directory rather than the model one —
which on Android is deliberately the directory that is *not* evicted, and is
the wrong home for a file that lives for one sentence. `flutter_pcm_sound`
would be lower latency and has no Linux or Windows. **On Linux the microphone is `parecord`**, which `record` shells out
to — `pulseaudio-utils`, which a PipeWire system has as well — so a machine
without it gets a voice session that fails to start rather than one that hears
nothing.

**Only text parts are spoken**, and sentence by sentence as they stream, so the
first sentence is being read while the rest of the reply is still being written.
`speakable` is what makes a reply worth hearing: markdown is written to be
looked at, so a heading read verbatim is a run of hashes and a bold word is a
word between asterisks. **Fenced code is dropped whole** rather than flattened —
a command read out character by character is unusable to listen to and unusable
to type from, and the conversation is still on screen for anyone who wants it.
`SentenceSplitter` is fed the whole reply each time rather than the delta, which
is what the controller has; it refuses to split on `3.14`, `main.dart` and
`e.g.`, and breaks a run-on paragraph at a comma rather than hold up the first
sound the user hears.

`SpeakableText` is the same bargain a second time: fed the whole reply, keeping
what it has already worked out. Stripping is eight passes over each line, the
transcript is redrawn on every flush of a turn, and the speech path looks four
times a second, so re-stripping the whole reply each time costs more the longer
it gets — the same growth the splitter is fed the whole text to avoid paying
twice. What makes it possible is that a reply only ever grows, so every line
before the last break is settled; only the line still being written is stripped
again, and its fence is not counted, since an opening fence is not open until
the line it is on ends. Both readers of a streaming reply use it, and it is
`speakable` that they still agree with.

**Settled lines are kept joined, not kept in a list**, and the `\n{3,}` collapse
is done as they arrive — a run of three newlines is two blank lines in a row,
which is a thing to notice on arrival rather than to scan the whole reply for
afterwards. Without both, a look still cost a join of every line and a regex
pass over all of it, which is the same growth one step quieter. The same reply
asked for twice is answered from the last answer, since a turn changes far more
than its text and the transcript is redrawn for all of it.

**The line still being written is trimmed rather than stripped where no rule
can reach it**, which is what settling cannot do anything about: nothing settles
until a line break arrives, so a reply written as one unbroken paragraph was
stripped whole on every look. The eleven patterns are two kinds. Six are
anchored to the start of a line — the fence, the rule, the bullet, the quote,
the heading, the table's own row, and the pipe handling with them — so they read
only how the line *starts*, which is fixed as soon as it has a character that is
not a space. The other five need one of ``* _ ~ ` [ <`` or `|` to fire at all.
A line with neither is one all eight passes are about to hand back unchanged,
so it is handed back unchanged. The markup is looked for once per character
rather than once per look, since it only ever arrives: a line that has any has
it for good, and falls back to being stripped for the rest of its length, which
is where every line was before this.

Measured over three hundred looks, microseconds per look, incremental against
whole: one paragraph, 6 against 234 at 4,000 characters, 24 against 928 at
16,000, 92 against 3,694 at 64,000; line-broken, 4 against 244, 10 against 973,
52 against 3,855. What is left growing is the copy of the answer, which is
what the answer is.

**Settling inside a line is the other answer and is not worth its price.** A
split point has to be outside every construct, and a sentence end is not one:
`. ` falls inside `[Fig. 3](x)` and `*One. Two*` as readily as a space does, and
the anchored rules re-fire on the tail, so `Words here. - not a bullet.` loses
its dash. Of thirteen splits at a `. `, eight change what is said. Making it
sound means a second, hand-written account of what those five patterns match,
kept in agreement with them forever — where the guard above is a set of seven
characters, and is wrong only in the direction of doing the work anyway.

It is tested against `speakable` at *every* length a reply passes through, which
is the only assertion that means anything about a thing whose whole job is to
agree with something else — and that is what carries the collapse being moved
out of the regex, since every run length has to agree at every prefix.

A sentence is generated ahead of being heard, so **the queue running dry is not
the end** — the session only says it has fallen silent once nothing is still in
the worker. Without that count a fast model reports silence between every two
sentences, which in voice mode flickers the circle and in a message being read
out would stop it after the first sentence. The WAV of what is playing is kept
until something else is: `play` returns when playback *starts*.

**Talking over the reply stops the turn as well as the speech.** The session
goes quiet the moment the detector fires, before the controller has decided
anything; the controller then aborts the turn, because interrupting means stop
and listen to me — which is Stop and then type, in one gesture, and leaves the
same aborted turn in the log. That rides on the platform's echo cancellation,
without which the model hears itself and every sentence is a barge-in; the Stop
button under the orb is the fallback, and shuts the reply up without leaving
voice mode.

#### Reading one message out

The row under a message has a speaker button, and it is **not voice mode**: no
microphone, no recognition model, nothing said back into the conversation. That
is `recognition` being null on `Voice.start` — a session with nothing to listen
with — rather than a second port, since what it does is the half of a session
that already existed.

`ReadAloud` owns it, and owns exactly one thing being read at a time. The
preview beside the voice picker in settings goes through the same notifier
under the id `preview`, so the two can never talk over each other and a second
copy of the model is never loaded to do it. Voice mode is the third thing that
can speak and is *not* under it, so `VoiceController.start` stops it first: a
message still being read out when the composer's circle is pressed would be a
second speech model in a second isolate, and two voices at once. Both buttons
that read something out go through `readAloud`, which is `toggle` plus the
snack bar its failure needs — the notifier has no `Scaffold` to say it in,
which is why it answers with a string. The session is let go the moment
the message has been read — a speech model is a hundred megabytes of a phone's
memory to hold for a button nobody may press again — and what says it has been
read is the session falling silent, since nothing above it can tell generating
from playing.

The button stays up while it reads, uncovered or not: stopping must not mean
going looking for the button that started it.

#### The screen

An orb of light, under the word for what voice mode is doing. It breathes on a
slow cycle while it listens and swells with the microphone on top of that,
sheds rings as it goes, orbits while a turn runs, beats as the reply is read
out, and sits dim and still while the microphone is shut — four looks to tell
apart across a room, which is the point of a screen nobody is looking at
closely. `VoiceBloom` decides what is running and `BloomPainter` draws it.

**The word is there because motion cannot say `starting` or `failed`.** It
replaced a Material glyph in the middle of the orb, which is a thing to decode
and was the only thing telling those two apart from listening. It is also the
semantics label, so what a reader hears is what is on screen.

**What a voice state looks like is the state's own business**, not each
widget's: `hushed`, `word` and `voiceColour` sit on `VoiceViewState` in
`voice_controller.dart`, because the orb, the dot beside the word and the Stop
button all have to agree, and the first version had the orb owning the four-arm
colour switch while the button re-derived one arm of it.

**Two controllers, and only because of the periods.** The rings and the orbit
are never on screen together, so they share `_cycle` and what a mode changes is
its duration; the breath is 1.9s against the rings' 2.9s and reading it off the
same controller would jump every time that one wrapped. Nothing runs at all in
the still mode — a hushed microphone repainted sixty times a second to draw the
same frame is a wake lock being spent on nothing.

**The two voices are the one place the scheme is left behind.** `heardColour`
and `spokenColour` in `ui/theme.dart` are flat indigo and teal rather than
`colorScheme.primary` and `tertiary`: a scheme's tones are picked to be read
*on* a surface, so the dark primary is nearly white and makes a pale smudge of
something meant to be lit, and an indigo seed resolves `tertiary` to a rose
that reads as a warning rather than as the other half of a conversation. The
hot middle of the orb moves *away* from the page — lighter in the dark, deeper
in the light — since a centre lightened on a white surface is a hole in the orb
rather than a light in it.

Three things about the drawing are worth knowing. The gradients — and the
paints holding them — are built once per colour and drawn as a **unit circle
under a canvas scale**, because a shader is a native allocation and a radius
that changes every frame would otherwise mean a shader every frame. A ring
travels from the orb *as it is now* to the edge of the box, so a swollen orb
does not push its own rings off the screen. And the box scales to the room the
column is given, since the same screen also holds a resume bar and a question
panel — by `AspectRatio` under a `ConstrainedBox` rather than by `LayoutBuilder`,
which would put every frame of the orb inside a **layout** pass: a build scope's
rebuild reaches its render object as `needsLayout`, and a `RepaintBoundary`
isolates paint, not layout.

**The page is split by what changes when.** `_Script` — the transcript, the
turn's surface and its questions — watches the chat, which moves sixty times a
second while a reply streams; the orb and the controls watch the session, which
moves a handful of times a turn. Watched together, every delta rebuilt the orb's
whole subtree and three `ButtonStyle`s with it. The bar's title is a third
watcher, on a `select` of its own.

A screen with the orb on it **never falls still**, so a widget test that pumps
one cannot `pumpAndSettle` — `pumpUntil` is what the tests reach for instead.

**Three buttons under it, one promise each**: Mute shuts the microphone, Stop
shuts the reply up and is dead unless there is one being read out, and Done
goes back to typing. They were the orb at first — which of the three a tap
meant depended on the status, so the same gesture stopped a reply, shut a
microphone or did nothing at all, and nothing on screen said the orb could be
tapped. So the orb now reports and nothing else. Stop is drawn in the reply's
own colour while it is live, since it is the one button that comes and goes
mid-turn. They sit bottom-most, where the composer is on the page this screen
stands in for.

Pausing is a *release* rather than a
stream left running and thrown away — the device stops recording, which is what
the system's own microphone indicator will say either way. It is a flag beside
the status rather than one of its values, because a turn can be running and its
reply being read out while the microphone is shut, and those are what the status
is for. Starting a session clears it: a fresh one listens whatever the last one
was doing.

**The transcript is a five-line window that scrolls**, not five lines that roll
past and are gone: it is a viewport over every line said, so the start of the
conversation is still there to scroll back to. Two things follow. Five lines is
a *height* — five times the line height at the current text scale, held rather
than measured, because a viewport cannot lay its content out to discover how
tall it should be, which is the same answer `_TitleLine.height` gives the app
bar. And it follows the newest line only while it is already at the bottom,
which is `chat_page.dart`'s slack rule reused rather than decided again —
`ScrollPosition.nearBottom`, whose slack is the only part either caller decides:
a reply streaming in must not yank the reader out of what they scrolled back to.

**Its top fades out**, into the orb above it, so the line being read is the one
at the bottom. A mask over the viewport rather than an opacity per line: what
should be faint is whatever is at the top of the *view*, and a line dimmed by
its place in the list stays dim once it has been scrolled back to. It is also
the one thing on this screen that finding a widget cannot check — a blend mode
on its own passes with the gradient upside down — so the test paints it and
samples what came out.

What the user said is `onSurfaceVariant` and what was said back is `onSurface` —
the issue asks for grey and white, taken through the scheme so light mode works
too. **A tool run gets a line as well**, dimmer than either voice: a turn can
spend half a minute inside a sub-agent, and a screen that says nothing while it
does reads as a broken app rather than a working one.

The way in is a circle left of the composer's send button, drawn wherever the
platform can listen rather than only where models are installed — with none
picked it leads to the settings that pick them, which is a better answer than a
button nobody can find. `openVoice` is that rule, and `startVoiceChat` beside it
is the empty pane's New Voice Chat: it asks about the models *before* it makes
the chat, since one created and then left on screen with nothing to say it with
is a worse answer than not making one. Both read `voiceReadyProvider`
themselves, which they can because **which models are installed is read before
the app is built** — `AppSession.start` scans for them and seeds
`InstalledVoiceModels` with what it found, the bargain `promptLibraryProvider`
already makes and for the reason it makes it. Asked lazily it is a disk scan
that answers "none" until it finishes, and a button's callback reads rather than
watches, so the first press would have offered settings to someone who has both
models however long the app had been open. That was first fixed by making it
the caller's problem — a `ready` parameter, and two comments saying it had to be
watched and not read — which is a contract every next way in has to be told
about, and is silently wrong when it is not. **It gives the field its width back the moment there is
a message in it**: something typed is something to send rather than to say. That
is an `AnimatedSize` around the button and nothing else — the row is laid out
again on every frame of it, and the `Expanded` field takes whatever it gives up.

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

### Being the assistant

Picked as the system's assistant, Entoli is launched by the gesture that used to
raise Google's — long-press home, or a swipe up from a corner — and opens a new
chat, in the project and the view the Assistant settings name. Android's, and
only Android's.

The manifest half is an `ACTION_ASSIST` filter on `MainActivity` and on the
`.PromptIcon` alias, for the reason the share filter is on both: whichever is
enabled is the only component that can be started, and being the assistant must
not stop working because the user changed the icon. `CATEGORY_DEFAULT` is
load-bearing rather than boilerplate — the role is offered to whatever
`queryIntentActivities(ACTION_ASSIST, MATCH_DEFAULT_ONLY)` finds exported, so
without it the app is not in the picker at all. Nothing else is needed: no
permission, and no `VoiceInteractionService`, which is the other way to hold the
role and is a great deal more than a launch signal.

**The launch is held rather than pushed**, which is the whole of what
`AssistantChannel` does. The gesture is usually what starts the app, and Dart is
not listening for a good while after that — so a launch waits in Kotlin until
`AssistantLaunch.take` asks, and the invoke behind `launched` is only a nudge
for an app that was already up. `FilesChannel` splits a share exactly this way,
and both halves are needed for the same reason, the cached engine included: an
activity whose engine was cached runs `onCreate` but not `main`, so the
first-frame read never repeats and the nudge is what carries that case.

`IncomingAssistant` wraps the app beside `IncomingShares` and is the same shape:
the postFrame read, the stream, and a flag so two gestures do not leave two
empty chats. It selects the project *before* it makes the chat, since
`startChat` and `startVoiceChat` both read `selectedProjectProvider` — which is
also what lets the view setting be nothing more than which of the two to call.
`AssistantView.voice` therefore inherits voice mode's own answer to missing
models: the settings prompt rather than a dead page.

A launch always makes a **new** chat. The gesture is how a conversation is
started, not how one is returned to, and the sidebar is still there for the
other thing.

The settings are app-level, with no per-chat override, for the reason the icon
and the theme are: the assistant is the app's, and the chat it opens does not
exist yet to have an opinion. Their category is drawn on every platform, the way
the voice one is where `Voice.available` is false — the settings are the app's
whatever it is running on, and hiding them would make the file's contents depend
on where it was last opened. `assistantProject` is `null` for the default
project, which is the null `selectedProjectProvider` already uses.

**It holds a name, so it is a weak reference**, and that is answered in two
places rather than one because they answer different halves. `deleteProject`
clears it, beside the `selectProject(ref, null)` already there — the setting is
the other reference to a project that has just stopped existing, and left
written down it is written *back* by the next save, so recreating a project of
that name would silently re-arm it. And both ends read it through
`projectOrDefault`, since a directory can also go behind the app's back: the
field shows `Default` and the gesture lands there, rather than the field saying
one thing while the gesture recreated the directory. One function in
`domain/project.dart` rather than the same test spelled twice, which is what it
was and which had already drifted — one end searched the list with the default
project in it and the other the list without.

### The theme

One palette, seeded from `entoliIndigo` — the colour the icon sits on, which the
seed used to miss by being `Colors.indigo` instead — and built in each
brightness by `entoliTheme`. `MaterialApp` gets both as `theme` and `darkTheme`
whichever is in use, so a system that turns dark at sunset turns the app with it
without anything being told. `AppTheme` — `system`, `light`, `dark` — says
which, and is app-level with no per-chat override for the same reason the icon
is.

Android's splash has followed the system since `minSdk` went to 26 and the
pre-Lollipop `launch_background.xml` could go. Until this landed the app did not
agree with it: a dark phone showed a dark splash and then a white app.

The exceptions are the two voice colours beside `entoliIndigo`, and why they
are not seeded is in "The screen".

`AppTheme` mirrors material's `ThemeMode` rather than holding one. Nothing in
`domain/` imports material — `core/config.dart` does reach `foundation`, so this
is about the framework's UI half rather than about Flutter at all — and the name
in `settings.json` should not be pinned to a framework enum's, which would make
the file unreadable if that enum were ever renamed. `ui/theme.dart` is the one
place that maps between them, and the label the settings page draws is on the
enum, the arrangement `AppIcon` and `ApproveMode` already have.

`entoliTheme` is a function rather than two `ThemeData` literals in `main`:
light and dark differ by a `Brightness` and nothing else, and a second literal
is a second thing to keep in step.

`main` watches the one field rather than the settings object. Without the
`select`, adding a provider or editing an environment variable would rebuild the
whole app under the user.

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
`Icon-512.png` is load-bearing off the web as well: the AppImage takes its icon
from it, a Linux desktop being no more switchable than a browser. See "The
Linux AppImage".

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

Every channel — this one, `ForegroundService`, `FilesChannel` and
`AssistantChannel` — is registered when the engine is created rather than on
each attach, and holds the application context. That is forced by the engine
outliving the activity: see "Staying alive off screen".

#### The debug build's own

A debug build installs beside a release one — its application id is suffixed
`.debug` — and until this landed the two were the same indigo cookie under the
same name, which makes the pair unusable for the one thing installing both is
for. So `src/debug/` overrides the label and the artwork: `@string/app_name` is
`Entoli (Debug)` there, and three drawables are the same paths with the indigo
turned black.

**The black copies are checked in, not tinted at build time.** A `tint` is one
colour over the whole layer, and the icon is a white cookie with the indigo
showing through it as the field behind and the glyph on top, so tinting flattens
it to a blob. Routing the two colours through a `@color` the debug source set
overrode would have worked; checked-in copies are what the rest of this section
already does, and the cost is the same one — the paths are duplicated, and
editing the artwork means editing both.

Both foregrounds, not only the cookie's, because the icon switcher still works
in a debug build and `ic_icon_background` is shared: draining it and leaving
`ic_prompt_foreground` alone would put indigo details on a black field. The
monochrome layers are shared as they are, being a single colour already — so on
a launcher with themed icons on, the two installs are the same silhouette again
and only the name tells them apart. That is the one case this does not fix.

`appTitle` in `ui/theme.dart` is the Dart half, beside `entoliIndigo` for the
same reason: it is the app's identity written where the platform's copy cannot
be read. It is not a second signal — `MaterialApp.title` *replaces* the launcher
label in Android's recents, so without it a debug build would name itself
"Entoli" there whatever `@string/app_name` said. `_AppBrand` reads it too, so
the bar over an empty pane is not the one place left saying "Entoli"; it is
`Flexible` now because the name is no longer a fixed width and the slot is a
phone's toolbar. It reads `kDebugMode` rather than the platform, so a debug web
build's tab says it as well, which is honest and free. Linux is left alone:
`my_application.cc` hardcodes the window title, `MaterialApp.title` does nothing
on GTK, and there is no second install to tell apart. Profile builds have no
`res/` of their own and so carry the release name and artwork.

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
rather than a question about models, and a model loaded there appears under
LLMs like any other. **Voice** is what listens and what speaks,
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

### Backing it all up

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

### Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` and
`OptionalModelPicker` (each a field over the model list, sharing the loading and
failure states every page would otherwise spell out) over
`ProviderModelSelector` (which owns every rule about the pair), the
`Default`-plus-reset pairing, `LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs and `copyToClipboard` beside them, `showAnchoredMenu`,
`NavDrawer` and `navBreakpoint`, `ActionIcon`, and `AttachmentChip` /
`AttachmentStrip`.

`ActionIcon` is the small icon button, and it carries the height the actions
row keeps whether or not anything is in it — the row and the buttons in it have
to agree on that, and a code block's bar now uses the same button. Its null
`onPressed` is the dead form, which is a thread arrow at either end of the
list. `copyToClipboard` is the other half of the same pairing: copying looks
identical afterwards whatever did it, so what was taken is said in a snack bar
from one place rather than each caller's own.

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

Send is dead while there is nothing to send, which `_worthSending` decides —
whitespace is nothing, a file on its own is something. `_submit` asks it again
rather than trusting the button, because Ctrl/Cmd+Enter reaches `_submit`
without passing the button at all.

Which way the button is driven is worth the two lines it takes to say. A
`setState` would rebuild the composer, and the composer's build resolves the
completion menu and its matches — no business re-running because a letter was
typed. Watching the `TextEditingController` directly fixes that but fires on
every `TextEditingValue`, so a bare caret move rebuilt the button and the
thirty-odd widgets Material puts under it for an answer that cannot have
changed. So it is a `ValueNotifier<bool>`, set from the listener the field
already has for the completion token, and the button redraws when the answer
flips rather than when the field is touched.

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
`release.yml` attaches the binaries, and `pages.yml` deploys the web app from
the same tag. Either can fail without the other, and only the first checks the
tag against pubspec — a version disagreement stops the binaries and deploys the
site anyway.

Two files are attached, each with a provenance attestation beside it: a signed
`entoli-<version>.apk` and a `entoli-<version>-x86_64.AppImage`. There is no
Play channel and so no App Bundle: the file on the release is the file that
gets installed. Both carry the app's name rather than the package's, since a
person is what downloads them.

**`release.yml` builds none of it.** The builds are `release-build.yml`'s,
which it calls with the tag and which is dispatchable on its own, so whether a
tag builds can be found out without publishing a release to ask. What the two
Linux builds then share is one composite action,
`.github/actions/linux-appimage`; they differ in the mode they pass it and in
what they do with what comes back, which is a bundle and an AppImage either
way. The four signing secrets are named at the call site rather than
`inherit`ed, since only one of the two jobs signs anything.

**The version is `pubspec.yaml`'s `version:` and nothing else**, resolved in a
job of its own before either build. Both file names are composed there, because
an attestation records its subject by name and the file attested is uploaded
from a different job than the one that built it. A tag disagreeing with pubspec
fails that job, since a binary reporting a version nobody released cannot be
talked out of it afterwards — and failing there costs seconds rather than two
toolchain installs.

**The Android version code is derived from that version rather than stored**,
as `major * 10000 + minor * 100 + patch` — 1.0.0 is 10000, 1.2.3 is 10203. So
pubspec carries no `+build` suffix: a suffix would be a second number to bump
and so a second number to forget, and forgetting it means a release that will
not install over the one before it. **Minor and patch must stay below 100**, or
1.0.100 and 1.1.0 compute the same code; the workflow fails rather than
shipping the collision. The debug builds are a separate application id
(`.debug`), so the run numbers `debug-build.yml` gives them are never compared
against these. They carry their own name and icon too: see
"The debug build's own".

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

**The publisher is a job of its own, so the one holding the keystore never also
holds `contents: write`.** It attests each binary with
`actions/attest-build-provenance` — one attestation per file rather than one
naming both, so a bundle on the release is about the file it sits beside — and
attaches the four, so a download can be checked against the build that made it:

```sh
gh attestation verify entoli-1.0.0.apk --repo Yiannis128/agent-chat
```

Splitting also means a failed upload re-runs against the artifacts that were
already built and checked rather than a rebuild that would have to be trusted
to match. **A job that never checks out has no git remote**, which is the trap
in that split: `gh release upload` reads the repository from it and fails with
`not a git repository` pointing at the runner, so the publisher names the
repository explicitly.

`workflow_dispatch` takes a tag and rebuilds an existing release for the same
reason: recreating a release to retry a publish changes its timestamp and
notifies every watcher a second time.

### The Linux AppImage

`flutter build linux` produces a directory that has to move together — the
launcher resolves `lib/` through an `$ORIGIN/lib` rpath and finds `data/`
beside itself — and a release asset is one file someone runs. So the bundle
goes into the AppDir whole and unrearranged, under `usr/bin`, and `AppRun`
execs it where it lies. Anything lifted out of it is a file the app cannot
open.

**The packaging is `linux/packaging/make-appimage.sh`, not a step of the
workflow**, and it takes a bundle and an output path. It is the only genuinely
new thing in the release machinery, and left inside a YAML step the only way to
try a change to it would have been to push and dispatch. The action builds and
then calls it; `linux/packaging/` holds what it assembles — `AppRun` and the
desktop entry, named for the application id the way everything else on Linux
is. The icon it takes is `web/icons/Icon-512.png` and its file name comes from
the entry's own `Icon=`, so there is one authority for that string.

**Nothing of GTK is bundled.** The AppImage carries the Flutter engine and the
plugins and links against the system's GTK 3, exactly as the bundle already
did.

`appimagetool` is pinned to a release rather than tracking `continuous`, and to
a SHA-256 beside it: it builds the file the release is attested by, and a
release tag can be moved. It is run with `APPIMAGE_EXTRACT_AND_RUN=1` because
it is itself an AppImage and a CI runner has no FUSE to mount one with. The
runtime it embeds is static, so the AppImage it produces does not send anyone
looking for `libfuse2`.

The debug one is uploaded beside the bundle rather than instead of it, and is
`entoli-debug-x86_64.AppImage` with no version in the name: it is dispatched
from a branch rather than cut from a tag, so pubspec's version would name a
build nobody released.

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
- Bundled tools (Android's git, proot and llama.cpp): `ANDROID_NDK_ROOT=~/.android/ndk/<version>
  tool/bundle/build.sh arm64-v8a` then `tool/bundle/stage.sh`. None of it is run
  by the app build; without them an APK has no git in it, no way to run a Linux,
  and no model server. The git half needs `perl` with `FindBin`, which the
  `flutter-dev` toolbox has and this host does not; the llama.cpp half needs
  cmake and ninja, which is the same toolbox again, and is built for arm64
  alone.
- The NPU is opt-in and wants Qualcomm's SDK, which is behind an account:
  `HEXAGON_SDK_ROOT=~/Qualcomm/Hexagon_SDK/6.6.0.1 tool/bundle/build.sh arm64-v8a`.
  Without it the build carries the CPU backend and the settings page says the
  device has no accelerator — see "What the NPU actually is".
- Codegen: `dart run build_runner build` (freezed + json_serializable).
- Analyze: `flutter analyze`. Tests: `flutter test` — see `test/CLAUDE.md`.
- The repo is not `dart format` clean and is not meant to be; match the file you
  are in rather than reformatting it.

## Dependency note

Freezed 3.x requires `abstract class Foo with _$Foo` (not just `class`).
Build runner capped at `^2.15.1` to stay compatible with freezed 3.2.5's
analyzer constraint. riverpod_generator dropped due to analyzer conflict with
freezed; we use manual Riverpod providers.
