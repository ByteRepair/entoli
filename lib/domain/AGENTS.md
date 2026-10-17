# The conversation and its records

## The conversation log

`conv.jsonl` is a log of `ChatRecord`s, one per line, appended as a turn happens
and never rewritten. It was a JSON document, and a document has to be written
whole to stay parseable — so it could only be written once a turn was over, and
a turn killed halfway left nothing at all. A line is complete the moment it is
written, so the only thing a kill can now cost is whatever had not been appended
yet. That is what makes an interrupted turn something to offer to continue
rather than something to apologise for.

Seven records. `message` opens one — before it holds anything, which is what the
empty assistant message at the head of a turn is — and its `siblingOf` names
what it is an alternative to, or nothing at all, which puts it on the end of the
thread being read; `replacesSibling` takes that one away rather than joining it,
and `documents` records what its `/skill` and `@agent` references stood for
when it was written — see "Commands and agents". `part` is one part of it, at an
index. `append` is more text
on the end of the part at an index. `turnEnd` closes the turn and says why:
`done`, `aborted`, or `error`. `select` says which of a message's alternatives
to read. `rewind` forgets a message and everything below it. `compaction` says
the conversation up to a message is summarized for the model, and still there
for the user to read — see "Compaction" below.

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
template), a `/skill` is expanded to its body, and a file part comes back as
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

**The room's mail is worded per viewer too.** A say the user addressed to a
member is, in every other participant's session, a user-role message naming
who it was for (`addressedUserTurnText`, off `Message.addressees` — the
room's own routing record, stamped at dispatch, empty for the house's mail) —
the way a peer reply names who wrote it; a model cannot be asked to read a
sigil in someone else's prose and know whose mail it is. What the addressee
reads is verbatim, and the task dress (`_firstTask`) is the message that
opened the *viewer's* work — the first own mail — which in a direct chat is
the conversation's opener, so the rule reduces there to today's bytes.
A peer reply is worded the same way off its own stamped addressees —
"addressed to you", or "addressed to @x (not to you)" — so a handoff to
someone else does not read as work for the viewer; an unrouted reply (old
logs, a reply naming nobody) words as it did. Only user messages are mail
for the dress: `addressedTo` is false for a reply.

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
this read any. And what a `/skill` or an `@agent` stood for is written into the
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

The directory a command left the shell in rides on the result the same way — a
`cwd` on the `ToolResult` and the user's `ShellRunPart` — and the projection is
what turns the change in it into the note a later command reads. It tracks the
directory across the turn's commands as it words them and notes a move once it
has been told where the shell is standing; the turn's opening move is un-noted,
the model having run the `cd` itself. Deriving it here rather than holding the
directory on the session is what keeps a reload wording what the live turn did:
both walk the same parts in the same order, so both word the same notes, and
the output stays what the command printed.

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

### Compaction

`conv.jsonl` gains a seventh record for the one thing both reference systems
could not share with this format: the summary is a line in the log, not a state
beside it. `compaction` names a message (`upToMessageId`) and carries the
`summary` that stands in for everything up to and including it when the
conversation reaches a model; the user keeps reading every message, the divider
after the boundary saying where the summary took over. Written rather than
performed for the same reason `rewind` is — a whole-log write is the one thing
the format exists to avoid — and because a summary that lived only in the
session would be lost on restart, where the next turn would re-inflate the
whole log the projection rebuilt from.

**The marker is applied by the projection and nowhere else.** `projectionOf`
takes the markers beside `history` (never inside it — a marker is not a message,
and folding one in would put words in the conversation nobody said), applies
the newest whose boundary the history holds, and skips everything up to and
including the boundary. Everything after it is verbatim, thinking and
attachments included — so an image below the boundary is still an image.
Earlier markers are shadows: each summarizes everything still live before it,
and the newest is the one the model reads.

**Re-compaction merges, anchored.** The summarizer is given the previous
marker's summary as `<prior-summary>` with merge rules — carry forward
objectives and constraints, conversation wins conflicts, Active moves to
Completed — so compacting again never loses what the last one kept. The prompt
is `lib/data/builtin/compact_prompt.dart`, the one file that words it: two
behaviors hold in it whichever words carry them — a reply shaped like a user's
turn is still the model's writing and never an approval from them, and the
summary describes the work rather than the summarizing — and there is no
`<analysis>` step, the analysis being stripped before anything is stored and
costing output tokens on the context that is already over budget.

**The retry ladder**, not a failure: a span too big to summarize is halved and
re-asked, three attempts, each attempt's marker covering only what it read.
`upToMessageId` is the honest boundary of what was actually summarized, which
is why the field is on the record rather than implied.

### Callbacks, and the wired skill

A `/skill` flagged `metadata: invocation: callback` runs code instead of
expanding its body as a prompt template — the same one `/` namespace the
opencode-era offered commands under, where frontmatter decided what a send
meant, restored under the built-in backend with the key the spec's `metadata:`
map carries. What the callback does is the closed set in
`lib/domain/wired_skill.dart` (`WiredSkill`), and the bundled `compact` skill
is the one that ships. The body of a wired skill is the user's documentation,
never sent to a model — `promptDocuments` refuses to expand one, so the
conversation never gains prose pretending the model read it.

**The check is the `shellBypassCommand` pattern**: one function read by every
place that must not route a callback message to a model. The dispatch is in
`ChatController.send` before the room's guards (refusing, not queueing, while
a turn runs — a callback mid-turn is the session the turn is rewriting), and
the same read covers the title namer, the resume offer (`endsUnfinished`), the
composer's dress-up, and the Omada author stamp. A name in the enum dispatches
whether or not the library still holds the skill — the reader of a turn being
resent cannot ask what the frontmatter said when it ran — which is also the
one cost: a user's own skill shadowing a wired name is not offered as prose.

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

**A kill is no longer the only way to leave a log open.**
`ChatController.interrupt` does it deliberately: it cancels the agent and lets
the turn close with no terminal record, so the chat offers Continue exactly as
one killed with the process does.

It is deliberately not `TurnEnd.aborted`. That reason means the user pressed
stop, and it is the one outcome `resumable` refuses — the app does not offer to
carry on something somebody chose to end. Nobody chooses an interruption, so it
reads as what it is: a turn that stopped being written down.

The mechanism is one flag rather than a second teardown. `_interrupted` is set
before the agent is cancelled, the way `abort` sets its outcome first and for
the same reason — cancelling closes the stream, so `_finishTurn` can run from
the `onDone` instead of from the caller, and both have to decide the same thing.
It clears where a turn opens, beside the recorder's own `outcome`. `_finishTurn`
then reads a `TurnEnd?`, and null is the no-record case — the same `?? true`
that `endsUnfinished` makes of a log missing one, so the state on screen and the
state a reload would build cannot disagree.

**Anything that stops watching a turn it did not choose to end wants this.** A
voice session handing the microphone to another is one — see "Taking turns".
`AppSession.dispose` is the other, through `interruptLiveTurns`: a restore or a
relaunch used to abort every live turn, so work nobody stopped came back
recorded as though they had.

It reaches only the chats a `ChatController` is already driving, and a
trigger's turn now has one — `TriggerRunner` drives the turn through
`ChatController` via `TriggerTurnDriver`, the same path the user and
`VoiceController` take, so `interruptLiveTurns` reaches it.

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
`sendPrompt`, because there is no prompt: no text, no attachments, no `/skill`
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

`createChat` writes the chat — `state.json`, the `meta.json` it was handed, and
the directories under them — and returns it. **What keeps an unused chat off
the disk is that nothing calls it until there is something to say**: the screen
with nothing selected is a screen rather than a chat, and it creates one as the
first message is sent. See "Nothing selected is a new chat" for that end of it.

It used to be the other way round. The repository held one *draft* — a chat
made but not written, with whatever `meta.json` would have said held beside it —
and the first `saveState` promoted it. That bought exactly one thing, an
untouched chat leaving nothing behind, and charged for it in every method that
could be handed a chat id: `openChat`, `saveState`, `retitle`, `loadMeta`,
`saveMeta`, `loadState`, `readRecords` and `projectOf` each branched on whether
this was the draft, `deleteProject` had to forget it, and `createHeadlessChat`
existed as a second creation path whose whole job was not to touch the one draft
slot — two reminders firing together would otherwise overwrite each other's.
Deciding *when* to create instead of *whether* to write buys the same thing and
costs none of that.

`ChatController` invalidates `chatListProvider` after the first save and after a
rename, and `createChat`'s caller does the same for the chat it just made —
those are the only things that change what the sidebar shows. Refreshing it on
every message would re-read every chat off disk to draw the same list.

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

## Skills and agents

`PromptLibrary` is the whole of what the composer's `/` and `@` menus offer,
and it is **per project**: the default project's is the base set every other
project inherits, and a project's own entry replaces a same-named default entry
for that project alone. `byte-repair`'s `esbmc-verifier` agent is byte-repair's
alone — the default project and any other see nothing of it — because the
generator tagged it with the project it belongs to and the library it is served
to filters by that tag. The library is built from two `PromptSource`s in
precedence order: the presets embedded in the binary (see the root notes,
"On-disk layout", for why they are code rather than assets, and for the
per-project tagging), then the user's own directory under the project. A skill
the user wrote replaces the preset it shares a name with, and entries come back
sorted by name, so the menu does not reorder when a source does. One library is
built per project at startup, because the directories are read off disk and
nothing downstream should wait on it; a skill dropped into the directory by
hand therefore does not appear until a restart, though nothing would break if it
did — a message resolves against whatever the library holds when it is
composed, and keeps the answer. The routes that buy a refresh are the places
that change the library from inside the app — the skills and agents settings
pages, at the app level and from a project settings page, and a `create_skill`
install — each reloads every project's library after it writes, so the change
lands without a restart. The same settings widgets serve both levels, under a
`project` parameter: a project's page writes that project's directory, and a
built-in's is the read-only view of the set it serves.

A skill is a **directory**, not a file: a `SKILL.md` and whatever files it runs
with. Its frontmatter is held to the [Agent Skills spec](https://agentskills.io)
— a `name` of lowercase letters, digits and hyphens matching the folder's, a
`description` of at most 1024 characters, and only the spec's keys
(name, description, license, compatibility, metadata, allowed-tools) at the
top level. Entoli's own keys (`argument-hint`, `user-invocable`,
`disable-model-invocation`, `invocation`) live under the spec's `metadata:` map, which is
its extension point for per-client settings — see "The conversation log" in
this file's parent for what the flags do. `skillProblems`, in
`lib/data/prompts/skill_validate.dart`, is the one validator, and it runs
everywhere a skill comes in: a `.skill` import refuses a non-conformant
package with the reasons, `create_skill` refuses a draft the same way so the
model can fix it in-process, the loader skips a folder that does not conform
with a log line, and `tool/gen_bundled_skills.dart` fails the build rather
than ship a preset the loader would skip. Nothing is migrated: a skill that
stops loading says so on its settings row and on the skill view page, and the
fix is to edit and reinstall it.

The folder is what a `.skill` import lands and what the base directory is, and
the spec requires it to match the frontmatter `name` — so the two diverging is
now a problem, not a normal state. Its body carries the base directory above
the template, because that is the one thing every reader needs and none can
work out. An agent is still one `.md` file: a system prompt, with nothing to
run beside it.

Beside the `.md` an agent may carry a profile picture, `<name>.png` in the
same directory — a PNG, picked in the editor, written and removed with the
agent. It is no part of the document: nothing parses it, nothing back-ups it
specially (a directory that grows a picture is still carried by the
members-are-files rule), and the model is never told of it. The picture a
project shows is read over the same tier walk the library answers mentions
with — a project's own answering over an inherited one — by
`readAgentPicture`, which the `agentPictureProvider` serves and the agents
list, the editor and the Omada reply's avatar read. A bundled agent has no
picture until the user's own agent of the same name carries one.

A skill has two halves to being reachable, and they are separate. **User
invocation** is a `/name` in the composer, offered while the skill is
`user-invocable` (the default); **model invocation** is the `skill` tool,
offered while it is not `disable-model-invocation: true`. A skill can be the
model's alone, the user's alone, or both: `user-invocable: false` drops it from
the `/` menu, and `disable-model-invocation: true` keeps it out of the tool and
of the system-prompt listing, so the model reaches it only because the user sent
it.

`PromptDocument` reads only the top-level scalars and the `metadata:` map —
`description` and the metadata keys are all the menu and the tool gates need.
The parsing itself is `Frontmatter`, in `frontmatter.dart`, its own file so the
build-time generators can read a skill's frontmatter without dragging the
freezed models into a checkout that has not run build_runner yet. The syntax is `_skillReference` and `_mention`, in
`prompt_library.dart`, beside the library they are read against rather than in
whichever layer happened to need them first. `activeCompletionToken` in
`CompletionField` has to agree with those two patterns: anything the menu
offers has to dispatch.

`/name args` expands to the skill's body with `$ARGUMENTS` substituted (or
appended); a name the library does not know is left alone, because it is more
likely a path. The `skill` tool hands the model the same body through the same
`withArguments`, so the two routes put the same words in front of it. `@name`
stacks that agent's prompt under the system message.

**The library is read once, where the message is composed, and never again.**
`ChatRepository.composeUserPrompt` is the only place a user's message is made,
and it calls `promptDocuments`: what each reference meant goes into the message
as `documents`, keyed by the reference as written — `/review`, `@researcher`,
sigil included, so a skill and an agent of the same name do not collide. Every
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
turn read whatever `skills/review/SKILL.md` says *now* — putting words in the
model's mouth it had never seen, and quietly changing a conversation the user is
reading beside it. A skill since deleted was worse: the turn fell back to the
four characters the user typed, and the model was asked to carry on from a
prompt it had never been given. Held, none of that is possible, and the message
that carried it says so on its face.

Old logs have no `documents` and default to an empty map, which renders as the
text alone — exactly what those turns already did. There is nothing to migrate
and no version to bump, the same bargain `siblingOf` made.

`agentPromptFrom` reads the same map for the `@agent` half, which is why a
resumed turn carries on under the agent the turn actually ran under rather than
whatever that name means today. The mentions stay in the text and are not
stripped, so what the user reads and what the model reads name the same agent.

**An `@mention` is not a participant.** It stacks instructions for the turn —
the reply is the main agent's — and who speaks is the controller's `_responder`
decision (see "The room and its participants" in `lib/ui/chat/AGENTS.md`).
Omada is what makes a mention promote the named member, in Omada-on projects.

`completions` is therefore **not** on `AgentBackend`: `completionsProvider`
is a family keyed by project, reading the project's library directly and
synchronous. The composer and the trigger editor pass the project they are in;
the repository's `composeUserPrompt` resolves the project's library through
`libraryFor`, so a message is composed against the same set the chat it lands
in will offer.

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

## Triggers

A trigger runs a prompt at a moment, after a countdown, or on a file change —
in a new headless chat, or in the chat that registered it. The pieces are
`Trigger` (the model and its sealed `TriggerSource`, `trigger.dart`), three
`TriggerKind`s (the behaviour, `trigger_kinds.dart`), `TriggerManager` (the
fire path over the kinds, `trigger_manager.dart`), and `TriggerRunner` (the
headless turn or the same-chat drive, `trigger_runner.dart`). The platform
halves are `ReminderAlarms` (the clock and the notifications) and
`FileWatches` (`file_watches.dart`; the impls under `data/local/`). The store
is `FileTriggerStore`, over `<dataDir>/reminders.json` — the file name the
reminder feature gave it, kept because a rename is a migration; legacy
records are triggers because `fromFromJson` — `Trigger.fromJson` — reads the
flat `at`/`repeat` shape a reminder was.

### The layers

- **Model, no behaviour.** `Trigger` and `TriggerSource` are data and JSON:
  schedule (`ScheduleSource(at, repeat)`, the reminder shape),
  `TimerSource(duration, registeredAt)` — "in thirty minutes", anchored by
  whoever registers it (the provider's `registerFor` re-dates a parse's
  placeholder to now) — and `FileSource(paths, events, cooldown)`. The
  recurrence arithmetic moved with the reminder, statics on
  `ScheduleSource`.
- **Kinds, the behaviour.** `TriggerKind` answers five questions: does this
  trigger match me; is it armed; what to watch; whether to defer the fire;
  and what it is next. The registry is the manager's parameter — a source is
  added by a line there, and nothing in the manager or the tools switches on
  kind. `ClockKind` is the schedule and timer share: the alarm diff, the
  catch-up at launch, the in-process timer, and the defer-to-alarm dance,
  all moved off the scheduler it used to be. `FileKind` is watchers over
  resolved roots — one root one watcher, per-trigger cooldowns, fires only
  while the process runs (nothing on any platform re-delivers inotify to a
  process that was not there) — paths resolved where the watch is built,
  through the file tools' own `resolveWorkspacePath`, so a stored
  `project:notes/` means what a `read` would have opened.
- **The manager** is the room's side: the kind registry, the single fire
  path — claim before the first await, defer, run, notify, stamp, reload —
  and the nudge. It owns no timer, diff, or watcher of its own: every one of
  those is the kind's.
- **The runner** resolves the target. `chatId` null is the reminder flow —
  `repo.createChat` with the trigger's meta, `headless` and
  `approveMode: never`. A chat id drives the turn in that chat, not
  headless (its `ask_user` has an owner); a chat that has been deleted
  disarms the trigger, with a notification saying so, and never re-points
  the prompt at some other conversation.
- **The driver** is the one `ChatController.send` path, as before.

### The agent's own

`AgentCapability.trigger` is what offers the trio (`trigger_set`,
`trigger_list`, `trigger_remove`); a sub-agent is not offered it (it is not
its own chat's), and a headless turn is — a reminder may arm its next run.
The registry the turn reaches is `ChatTriggerRegistry` — one chat's face
over the list — built by the backend like `saveArtifact` is, with the
provider's notifier behind it, so a registration is on disk and under watch
the moment the tool answers. The chat's project travels with the registry:
a timer's `registeredAt` is the registering moment, and the member a
`trigger_set` names is checked against that project's library there — an
unknown one refuses the registration with what was not found, the model's
error to fix. `trigger_set`'s parse is
`triggerDraftFromArgs` and the registry anchors and stores; a timer's
`registeredAt` is the registering moment, not the parse's. A one-shot whose
moment is already past is refused at registration — `triggerScheduleProblem`,
the editor's future-guard shared at the anchor site — since a trigger armed
against nothing answers success and fires nowhere.

### Who a fire addresses

`Trigger.member` is a name an Omada room routes the fire to, wherever the
fire lands — one shape, no branching on the target: a chatless fire makes
its headless chat with the member as its first speaker, a same-chat one
queues on the member's FIFO. The runner puts the sigil'd mention on the
head of the send text (`prompted(prompt, reason, member:)` — the one
wording, the mention ahead of the prompt, the kind's reason below), and
everything after that is the room's own machinery: the composer resolves
the reference into the message's documents, `mentioned()` reads them, the
FIFO and the author stamp follow, and the fire is generation zero — the
user's own message analog, uncapped itself, its handoffs capped. In a
direct chat nothing stamps; the mention rides inline as instruction
material, the same rule any message the user sends takes. Validation lives
where the library happens to be — registration and the editor — while a
stored member later deleted is not re-checked: at fire time a name the
library does not hold is prose, which the room's mention filter already
answers.

### What a fire says

The kind words its reason ("schedule: <the moment>", "file <path>
changed"), and the reason rides in the prompt the runner sends — a line
below what was set, so the log says why a turn started. The completion
notification words the outcome as it always did, "Ran late" where catch-up
found it so. The completion notification's tap is the chat the turn ran in,
whatever the target; a same-chat trigger's completion is the conversation
itself, and the notification is where it answers for a turn that finished
unwatched.

