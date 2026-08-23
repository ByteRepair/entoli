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
thread being read; `replacesSibling` takes that one away rather than joining it,
and `documents` records what its `/command` and `@agent` references stood for
when it was written — see "Commands and agents". `part` is one part of it, at an
index. `append` is more text
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

**Nothing else words a conversation for a model.** What the model is shown of a
user's message is not what the user typed: it carries the moment it was sent,
the one that opens a conversation is dressed as a task (upstream's instance
template), a `/command` is expanded to its body, and a file part comes back as
the bytes it names. `BuiltinAgent` used to word the turn it was about to run
while the projection worded that same turn read back out of the log, and for a
long time the two disagreed — the log holding only what was typed. So a chat
reopened after a restart, and every regenerate, sent text that was not what had
been sent before. Nothing was visibly wrong, which is why it lasted: the model
answers either version. What it cost was the on-device KV cache, where a prefix
that differs by one line is a prefix that misses, so reopening a long chat
reprocessed the whole history — the exact wait that cache exists to remove.

**The fix was not to make the two agree.** `_openTurn` projects the message it
is about to log, so the session a turn runs against is filled by the function
that would rebuild it, and "what the model is holding" and "what a reload would
build" are one expression rather than two kept level by hand. It is why
`sendPrompt` takes a `Message` rather than a text, a date and a list of
attachments: the pieces travelling separately is what let them be assembled two
ways.

### One accumulation

Wording a turn once was half of it. A turn was still *built up* twice — the
agent appending `LlmMessage`s to the session as it went, the recorder
accumulating `MessagePart`s that became `conv.jsonl` — and every divergence
found so far was one of the two having drifted from the other. That is a kind of
bug that regenerates: fix the wording and the next feature adds a new place to
forget.

So the agent no longer accumulates. It emits events, as it always did, and
`_recorded` puts every one of them through a `TurnRecorder.parts()` on its way
out — the same class, the same `handle`, that `ChatController` uses to write the
log. What the session sends is then a function of those parts:

    scaffolding + prefix + projectionOf(the turn's parts so far)

`_sayWhatWasSaid` rebuilds the last term after every step and once when the turn
ends, through `BuiltinSession.replaceTurn`, which is the only thing that writes
to a session while a turn runs. `_answer` and `_answerRun` are gone; so is
`session.messages.add(completion.message)`. A tool result reaches the model
because it was reported, not because it was also appended.

**This is what makes parity structural rather than tested.** `AgentEvent` and
`MessagePart` are both sealed, and the switches over them — `TurnRecorder.handle`
and `_inResponse`, the projection's `_assistant` and `_responseIdOf`, and
`SubAgentRunner._drive` — enumerate every member with no default. Add a chat
feature and the compiler stops in the places that decide what it means to the
model, and deciding once gives the live turn, the reload, the regenerate and the
KV prefix together. Before, the compiler caught the projection half and said
nothing about the live half, which was a hand-written append. The two
`responseId` switches were the exception until this landed, and the pair matters:
a part stamped with no response reads back inside whichever response came before
it, which is a wrong answer nothing would have asked about.

What it costs is that a turn re-words itself once per step, where the old append
worded each result once and kept it. The expensive half of that is encoding a
long command's output as JSON, so `observation` is memoised on the result it
words — the results are immutable and only the last response can still change.
The rest is a `StringBuffer` per response, which is what the old path paid to
send the session anyway. A cheaper shape exists if it ever bites: only the last
response's messages can change between steps, so the ones before it could be
kept. That rests on no result landing in a later response than its call, which
is the same thing the fan-out ordering below establishes.

Two things stay outside, and they are the same two: the system prompt and the
resume nudge. Neither is in the log, both say how to run *this* turn rather than
what was said in it, and both are rewritten per turn rather than accumulated —
`_setSystemPrompt` and `BuiltinSession.forTurn`. They are now the only things
placed into a session by hand, which is a better home for the exception than one
hidden among a hundred appends.

The ordering it fixes is worth naming. A `task` fan-out used to emit each call
as its sub-agent resolved, so the log held them in finishing order while the
live session held the model's own — and the hand-answering loop underneath had
a comment explaining that it answered "in the original order, so the session
messages pair up". The calls now go out together, in the order the model made
them, and the projection pairs each result back by id. The comment went with the
loop.

**What a new tool owes the turn is one rule: report the call, then report the
result.** The projection builds a response's calls from its `ToolCallPart`s and
looks each result up by id, so a result whose call was never reported has
nothing to hang on and is dropped — silently, and now from the live session too,
since that is the same list. Stopping a turn used to be exactly this: the calls
it never reached were answered "not executed" into the session and nothing was
reported, so the log had the answer's call missing. Both halves go out now, and
the model is told a call it made went unrun instead of the call quietly ceasing
to have happened.

That puts the whole burden on the log, which now has to hold everything the
wording needs. The date is the message's own `createdAt`, so a regenerate — which
re-runs the message rather than a copy of its text — sends the date that turn
was sent under. The bytes are read back through a `ResourceLoader`, and that is
the only reason the projection is asynchronous; a file whose resource has gone is
left named rather than failing the turn, which is what every message did before
this read any. And what a `/command` or an `@agent` stood for is written into the
message when it is composed — see "Commands and agents".

**`resume` is the one message a turn shows the model that nobody said.**
Carrying on an interrupted turn puts a user message in front of the model —
`continueTask`, the reason it is being asked
again — and nothing logs it, because nobody said it. Left in the session it made
a chat resumed in this process hold a message a reload could not rebuild, so
every later turn in that chat sent a prefix `conv.jsonl` disagreed with: exactly
the miss this all exists to remove, in the one place still capable of causing
one.

It is not part of the conversation, though. It says how to run *this* turn, which
makes it the same kind of thing as the system prompt — and the system prompt is
rewritten every turn rather than added to, for this reason. So `resume` takes it
back out when the turn ends, and the session is again what the log says. The
alternative was to write it down, as a part of the reply the projection re-reads;
that keeps more of the cache — the resumed span keeps its place, where dropping
the message shifts it and costs one reprocessing on the next turn — but it puts
a message nobody sent into the record of what was, to make a cache faster. The
log describes the conversation. This does not belong in it.

**A result is worded once too, by `toolResultText`**, and that was the same bug
one layer down. The agent answered a call as the turn ran and the projection
worded that same result again out of the log, and for the file tools the two
said different things: `read` told the live model `File not found: notes.txt`
and told a reloaded one the JSON `observation` of a result with that in
`exceptionInfo`. Reading an empty file said `(empty file)` live and `(empty)`
from the log. Publishing an artifact told the live model how to update it and
told a reloaded one only that it existed. So any chat that had read or edited
anything — most of them — diverged the moment it was reopened, at every one of
those results.

Now a turn reports the `ToolResult` the conversation records and the projection
words it — the agent does not answer the model at all, so there is nothing to
hand a different value to. An `ask_user` still reads as the answers themselves
rather than as a command's outcome — it is the user talking — but only when it was answered:
one that failed has its reason in `exceptionInfo` and no answers, so it reads
like any other failure. That last part was wrong on both sides before, and
silently: the model was told nothing at all.

A call whose result never landed is answered anyway, since a provider that sees
a tool call with no result rejects the next turn — worded by what was called,
which is the next section.

Everything that puts messages in front of a model reaches for it. `_openTurn`,
for the turn being sent. `resetSession` on a rewind, which is what it replaced —
the old path wrote the kept messages out as prose and told the model "earlier in
this conversation", losing the thinking, the calls and the results. `sendPrompt`,
which fills a session that is empty: sessions live in memory for as long as the
app does, so a chat opened after a restart has none, and the model would have
been answering the next message having seen nothing of the chat. And
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

Reading the bytes back is the expensive half of that, and it is worth being
clear about which direction the parity was closed in. A live session has always
held its attachments as bytes, for every turn of the chat, for as long as the
app runs; it was the *rebuilt* session that named them and sent nothing. So this
did not make a running conversation more expensive — it made a reopened one cost
what the running one already cost, which is the side to land on, since the other
would take an image away from a model halfway through being asked about it. What
it does mean is that an image-heavy chat is re-encoded on every step of every
turn, and that compaction is what bounds it, exactly as with the text.

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

A turn the user opened with `!` is never offered either, whatever closed it or
failed to — the same rule once more. Resuming appends to the reply, and a
command has nothing to append: the only way to carry one on would be to run it a
second time, which is not continuing it. See "Running a command yourself".

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
is the log the user is reading. What it adds — `continueTask`, the reason the
turn is being asked again — it takes away when the turn is over, so a session
that has been resumed is still one the log could rebuild; see "The projection".

`AgentBackend.resumeTurn` is a method of its own rather than a flag on
`sendPrompt`, because there is no prompt: no text, no attachments, no `/command`
or `@agent` to expand. Its `@agent` prompt comes off the last user message of the
history — off that message's own record of what the name meant, so a turn
interrupted last week carries on under the agent it started under. What the two
share is `TurnSettings`, resolved once by `ChatRepository`.

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

**`retitle` takes a chat id, not a `ChatState`.** The namer's copy of the chat
is from before the turn it is naming, and that turn's own `saveState` has since
resolved the TTL and written an anchor onto the stored one — so `ChatStore.retitle`
re-reads what is on disk and sets the title on that. It used to write the
caller's copy back whole, which took the anchor with it: a temporary chat that
got named then had a TTL to be deleted on and no `tempTtlSince` to count from,
so no hourglass in the sidebar and no countdown in the bar, until a second turn
re-anchored it a day late. Taking an id is the fix that keeps: there is no
stale state to write.

`ChatController` is the other half. `saveState` returns what it wrote *because*
it is not what went in, and the head of a turn keeps that return rather than
the copy it passed — otherwise the bar draws a chat with no anchor for the rest
of the turn, and everything the controller writes from there carries the gap.

A `!` message names nothing either, and `suggestTitle` is where that is decided
rather than in the controller that calls it — it is the same kind of rule as "no
title model is configured", and it belongs beside it. A command is not a thing
said, and asking a model to name one is a model call on the very turn the user
routed away from a model, in a chat that may have no provider at all.

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
does not appear until a restart, though nothing would break if it did — a
message resolves against whatever the library holds when it is composed, and
keeps the answer.

A prompt file is YAML frontmatter, then the template a command expands to or the
system prompt an agent runs under. `PromptDocument` reads only the top-level
scalars — `description` is all the menu needs.

The syntax is `_command` and `_mention` in `prompt_library.dart`, beside the
library they are read against rather than in whichever layer happened to need
them first — `BuiltinBackend` held them when it was the only thing that expanded
one. `activeCompletionToken` in `CompletionField` has to agree with those two
patterns: anything the menu offers has to dispatch.

`/name args` expands to the command's body with `$ARGUMENTS` substituted (or
appended); a name the library does not know is left alone, because it is more
likely a path. `@name` stacks that agent's prompt under the system message.

**The library is read once, where the message is composed, and never again.**
`ChatRepository.composeUserPrompt` is the only place a user's message is made,
and it calls `promptDocuments`: what each reference meant goes into the message
as `documents`, keyed by the reference as written — `/review`, `@researcher`,
sigil included, so a command and an agent of the same name do not collide. Every
later reading renders from that map: the turn being sent, the chat reopened
tomorrow, a regenerate a week later.

It is on the repository rather than in `ChatController` because that is what
makes it unskippable. The controller was the only sender when this landed, and a
second one — a headless entry point, a share target that sends rather than
prefills — would have compiled perfectly while quietly sending the four
characters the user typed. Composing a message is now the same kind of thing as
resolving which model answers it: something the repository does for a turn, with
nowhere else to get one.

It was re-parsed against the library each time before, and that is wrong for a
reason nothing catches. These are user-editable files, so rebuilding a year-old
turn read whatever `commands/review.md` says *now* — putting words in the model's
mouth it had never seen, and quietly changing a conversation the user is reading
beside it. A command since deleted was worse: the turn fell back to the four
characters the user typed, and the model was asked to carry on from a prompt it
had never been given. Held, none of that is possible, and the message that
carried it says so on its face.

Old logs have no `documents` and default to an empty map, which renders as the
text alone — exactly what those turns already did. There is nothing to migrate
and no version to bump, the same bargain `siblingOf` made.

`agentPromptFrom` reads the same map for the `@agent` half, which is why a
resumed turn carries on under the agent the turn actually ran under rather than
whatever that name means today. The mentions stay in the text and are not
stripped, so what the user reads and what the model reads name the same agent.

`completions` is therefore **not** on `AgentBackend`: `completionsProvider`
reads the library directly and is synchronous.

## Resending a message

Edit and regenerate run the turn again as another thread beside it, rather than
discarding what was there. The live session still holds the thread being left,
so `resetSession` drops it and puts back `projectionOf` the messages above the
branch — thinking, calls and results and all. This is where the "conv.jsonl is
the source of truth, re-inject context" rule is exercised, and the projection is
what makes it true rather than approximate — attachments and all, since it reads
the bytes back off `resources/` rather than naming the files.

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
are in `conv.jsonl`, so a resend passes the parts along and never touches the
bytes — `saveAttachments` is the composer's alone, and an `Attachment` is only
ever a file on its way to disk.

It used to be both. A resend read every attachment back into `Attachment`s so
the turn could be sent with them, and `saveAttachments` then had to notice they
were already saved and not save them twice. Once the projection read the bytes
itself, that whole round trip was reading a file to hand it back to the code
that had just written it — so the load went, and `Attachment.resource`, which
existed for no other reason, went with it.

It is also what the model sees. `projectionOf` reads each resource back through
the loader the backend hands it, so an image is an image on every reading of the
conversation and not only on the turn that arrived with it — the whole reason the
projection is asynchronous. A resource that has gone leaves the file named in the
text and nothing else, which is what every projected message did before this.

The store's resource I/O is async where the rest of it is sync: a JSON file is
small enough to write on the UI thread, an attachment is not.

## Reminders

A reminder runs a prompt in a new chat at a scheduled time, headlessly — nobody
is watching, and on Android the process may have been dead since it was set. The
pieces are `Reminder` (the model, `reminder.dart`), `ReminderRunner` (the
headless turn, `reminder_runner.dart`), `ReminderScheduler` (the timer and
catch-up, `reminder_scheduler.dart`), and `ReminderAlarms` (the platform port,
`reminder_alarms.dart`). The store is `FileReminderStore`
(`data/local/file_reminder_store.dart`); the port's Android impl is
`AndroidReminderAlarms` (`data/local/android_reminder_alarms.dart`).

**The runner is `ChatController._turn` without the UI.** It composes the prompt
through `repo.composeUserPrompt`, writes the opening records through a
`TurnRecorder`, drives `repo.sendPrompt` to completion, and closes the log with
a `turnEnd`. Skipping any of those shows up elsewhere: no `turnEnd` and every
later open offers to resume; no list invalidation and the chat is invisible until
restart. The chat is created through `repo.createHeadlessChat`, which writes
state and meta together and never touches the draft pair — two reminders firing
together would otherwise overwrite each other's draft and orphan a `meta.json`
under the wrong project.

**A headless turn must not park on an answer.** `TurnSettings` carries
`offerAsk` and `offerTask` (defaulting true); `sendPrompt(headless: true)` turns
both off, since an `ask_user` parks the turn on a completer nobody will complete
and a `task` fan-out could do the same through a sub-agent. `meta.approveMode` is
pinned to `never` for the same reason: an approval banner nobody presses is a
turn that never ends.

**How long the chat lives is the reminder's `tempChatTtl`**, written onto its
`meta.json` as it is, null and all — the same field the chat settings page sets,
inheriting the project's or the app's answer where it is null. It was a bool,
and a bool could name only one of the five TTLs; `fromJson` still reads the old
key, where false meant `TempChatTtl.off` and true meant inherit.

**`lastFiredAt` is stamped before the turn runs, never after.** A crash mid-turn
costs a notification but must not re-run the whole prompt against the workspace.
The stamp goes through `onReminderFired` before `sendPrompt` is called; the
scheduler recomputes `nextFireAt` after the turn completes. A one-shot that
fired has `nextFireAt` null (nothing armed); a repeating reminder moves to its
next occurrence.

**Dart is the sole arbiter of what runs.** Kotlin only nudges — an id stashed
beside `ReminderAlarms.takeFired` — so whichever of the three triggers notices
first (the in-process timer, a nudge, startup catch-up) stamps the reminder and
runs it, and the others find the stamp moved. A single-flight set keyed by
reminder id guards against the overlap, and the id goes into it **before the
first await** — asking the platform anything is a round trip, and two triggers
either side of one would both find nothing running.

**A fire the platform will not hold is handed back to the alarm rather than
run.** `_deferToAlarm` asks `ReminderAlarms.canHoldTurn` and, where the answer
is no, re-arms the reminder for the time it was already due instead of starting
a turn — the system delivers that at once, and its broadcast is the one moment
a backgrounded app may hold the process open. Off screen the timer was
otherwise starting turns nothing could keep alive, which Android kills partway
through the reply, leaving the user a chat to press Continue on. Never twice
without a run in between; `canHoldTurn` is true wherever there is nothing to
ask, so this is Android's problem alone. See "Waking for a reminder" in
`android/CLAUDE.md` for the other end, and for the hold the receiver takes and
`doneFiring` releases.

**Catch-up fires overdue reminders at launch**, the same lazy semantics the
temp-chat sweep uses. A one-shot more than two minutes past its time says
"Ran late" in its completion notification; an exact alarm arrives within
seconds and does not.

`nextFireAt` is precomputed and persisted, not derived on the Kotlin side: the
boot receiver reads `reminders.json` with no engine running and arms AlarmManager
against the times Dart already worked out. A second copy of the recurrence math
in Kotlin would drift from this one across DST and month ends.
