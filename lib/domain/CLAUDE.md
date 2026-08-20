# The conversation and its records

## The conversation log

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

### Threads

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

### The projection

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

### Carrying on an interrupted turn

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

## Starting a chat, and naming it

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

## Commands and agents

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

## Resending a message

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

## Attachments

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
