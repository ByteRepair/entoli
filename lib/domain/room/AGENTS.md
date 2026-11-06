# The room

## The room and its participants

A chat is a room, and `ChatRoom` is it. Every widget on the chat page
renders a fact about the room; none of them permits or refuses anything.

The room is plain Dart, in pieces that each answer one question:

- **`ChatRoom`** — the turns in flight, what was said while they ran, the
  log they append to, threads, approvals and questions. Its state is
  `ChatViewState`, which it owns.
- **`Schedule`** — who speaks next: the per-member FIFOs, the parked wave,
  the generation cap. No I/O; the room hands it the one call that opens a
  turn. `OmadaOrdering` carries the policy as two methods, `admits` and
  `waitsForWave`, rather than a scheduler per ordering.
- **`Roster`** — who is in the room and who a message addresses. It is the
  one place routing is decided: a direct chat is a roster of one.
- **`Agent`** — a participant that takes turns, over the repository's
  `sendPrompt` and `resumeTurn`.
- **`RoomHost`** — what the room needs of whoever holds it: settings read at
  each use, where its state goes, and the services around a turn (naming the
  chat, the failure notification, auto-compact). `ChatController` is the
  host: a Riverpod `Notifier` that builds one room and implements
  `TurnDriver` over it.

The user is not a class: nothing in the room calls them. Their verbs are the
room's public methods, reached through `TurnDriver`. Sub-agents are not
rooms either — they share `TurnRecorder` with the room and nothing else, and
their transcript deliberately leaves the task unlogged (see "Their own
transcripts" in `lib/data/builtin/AGENTS.md`).

**A room is a list of participants.** A direct chat — Omada off, the
default — holds one: Athena (`athena`, a bundled agent like any other,
`assets/prompts/projects/default/agents/athena.md`). An Omada chat holds
every agent the project's library has, Athena among them. Nobody is special
to the room: every turn is a participant's, run under that participant's
file in a session of its own, and every reply names its author.

- **The user** speaks through `TurnDriver.send` — every way a trigger or a
  voice utterance speaks goes through the controller's `send` too, one path
  rather than one per caller. A trigger fire naming a member is a say like
  any other: the mention in its text is what routes it.
- **A say goes to the participants it names, or to the default route.**
  `Roster.mentioned` reads the agents the say's references name and keeps
  the ones in the room; where it keeps none — a say naming nobody, a `!`
  command, a callback — the say is the default route's, Athena today. So
  every say is addressed to someone, and `Message.addressees` always says
  who.
- **An `@mention` of an agent not in the room is a delegation.** The
  participant answering is told the user wants that agent to do the work,
  and hands it over with `task` — a sub-agent, headless and off the record,
  its output readable by its delegator alone. In a direct chat that is every
  mention but Athena's own; in an Omada chat there is none, every agent
  being a participant, and `task` is dropped.
- **What a participant may use is its own.** A participant's turn and a
  sub-agent's both run as the agent's `AgentDefinition`, so its `tools:` list
  holds in either role; see "Tools per agent" in `lib/domain/AGENTS.md`.

### The contract between direct and Omada chats

The two differ in who is in the room, and in nothing else the room decides.
**A direct chat** is the user and Athena: every say is hers, a reply naming
someone hands to no one (there is no one else), and a mention is a
delegation. **An Omada chat** adds the project's agents as participants: a
say naming members is answered by them, members hand off to each other by
mentioning one another in a reply, chain-capped, and a participant may
decline what it was handed with `end_turn` — never a say that reached it by
default. **Turning Omada off ends promotion for every turn
after it**, whatever the prompt names; what is already on the record stays —
history is fact. A regenerate answers the prompt again as it would be
routed now: by the agent it named while that agent is still in the room, by
the default route where it was deleted or Omada went off since. A reply is
carried on only by whoever wrote it, since carrying on appends to their
reply; one whose agent was deleted fails, saying so, and regenerating it is
the way on.

**The label is who spoke.** `Message.author` is stamped on every reply with
the participant the schedule routed the turn to, and nowhere else: never
where a participant merely used another agent's instructions, which would
put a name on a voice that was not theirs.

**The routing record rides the say.** `Message.addressees` is stamped where
the say is written — a fresh send in `_openTurn`, a say queued while the room
ran in `_sayLater` — with who the room resolved it to, sigils on. A reply's
is stamped on its `turnEnd` record when it closes `done` — its routing is
only known once its text is — and the handoff schedules off that stamp, not
a re-read of the text. A reply never addresses its own author: "hello @a, @b
and @me" was every member rescheduling itself. It is room data, not text:
`references` say what the text *named*, this says who the room sent it
to, and a member deleted from the library after the fact does not rewrite
the room's past. The wording half of it is the projection's, per viewer —
see "The room's mail is worded per viewer too" in `lib/domain/AGENTS.md` —
and what makes each participant's session current with it is the
dispatch-time sync, **`_syncSession`** (see "The agent loop":
`BuiltinBackend._syncSession`): every dispatch's history is the room's
whole thread, and a participant's session words what it has never heard,
confirmed against the log before a word is appended.

**Logs from before Athena had a name** were brought forward by the 7.5.0
migration (`lib/core/migrations.dart`): every reply with no author became
hers, every say with no addressees was addressed to her. The sync protocol
moved to 6 in the same release, so no older build's records reach a newer
one. Nothing reads the older shape.

**The room contract is My Team's note, not a per-turn overlay.** Every Omada
turn runs under `MyTeamProject`'s bundled note (`assets/prompts/projects/
my-team/system/instructions.md`): the room, the handles, `end_turn`, and that
every other participant's handle in a reply is handed a turn — worded once
for every participant. Each tells which one it is by the `You are @name`
line `participantInstructions` opens its prompt with. The project's own note
comes first where it ships one, and the user's instruction files are read on
top, the way they always are for a user project. A project's Omada answer
decides whether the note is there at all — a built-in's spec (`my-team` on,
everything else off), a user project's toggle — so flipping Omada off leaves
the next turn the plain prompt it had.

**The schedule is the room's order of speaking.** `Schedule.addPrompt` and
`addHandoff` put an item on each member's FIFO: a user prompt addressed by
its references, or a handoff — the reply that names them, one generation past
the turn that wrote it. `Schedule.dispatch` runs what the schedule holds,
asking the ordering's `admits` per item: **sequential** order
dispatches one item at a time — the mention list is the schedule, and what
follows dispatches at the settle it causes. **A member holds at most one
waiting handoff**: a later reply naming them replaces it — the later in the
thread kept, so the earlier is in the turn's history — rather than queueing
a second turn. Without that a room whose members all name each other fanned
out by the member count every wave, and the generation cap bounds depth, not
breadth (a three-member chat ran 85 turns under a cap of ten). **parallel**
order dispatches
one item per member at once, each FIFO's head, one turn per member still
standing, and the rest at the settles they cause; **relay** order keeps the
per-member rule and drops the wave barrier — the head of every FIFO whose
member has no turn in flight, dispatched while anything else runs. Either
way the item is off its FIFO before its turn opens, so a settle re-entering
finds the schedule behind it and not the item running.

**A handoff wave waits for the room to settle — in the wave orderings.** A
turn that finishes while a sibling is still speaking parks its reply
(`Schedule.park`); the settle the last sibling causes evaluates every reply
the wave finished, in finish order, against the cap read at dispatch. Relay
has no wave: a reply is evaluated the moment its turn is over, siblings
beside it notwithstanding, and what it names runs through the per-lane check
at dispatch — which is what "members start as soon as they are named" costs.
A generation is the dispatch wave an item belongs to — zero is the user's
own and uncapped, a handoff lands one past the turn that named it, and the
cap (`omadaMaxGenerations`, project override over app default) stops the
wave that would pass it. Under relay the finished turn's generation entry is
spent when its handoff is scheduled — waves overlap, so a wave's cleanup
cannot be the thing that retires the entry.

**A participant says nothing by calling `end_turn`, and silence is not a
row.** A reply is a message, and a model given only messages writes one — a
thank-you, an "all set" — that hands the room another turn; a text `pass`
convention was tried first and models wrote around it. The tool takes an
optional `reason`, ends the loop without another model call, and leaves the call on
the log. A reply that ended with it and wrote no text (`endedSilently`)
names no one, so it hands to no one; it is not drawn (`entriesOf`) and not
worded into any other participant's session, and it shows no running label.
It does not clear what siblings handed off — silence is nothing said, not a
veto.

**A say nobody else was asked cannot be declined.** `end_turn` is offered
where the turn may decline its say, which the room decides as it opens the
turn (`Roster.byDefault`, carried to the backend as `mayDecline`): a handoff,
or a user's say that named its answerer, may be declined — the name may have
been incidental, and someone else is answering. A say that reached its
answerer by default — one naming nobody in the room, a command, a callback —
is the only answer the user will get, so the tool is not offered and silence
is not possible. The rule is the route's, not a name's: it holds whoever the
default route is. A resumed turn is carrying on a reply, never declining
one, and is not offered it either.

**A say is not refused: it steers, or it is queued.** See "Steering a turn"
below for the default. A queued say — `send(queue: true)`, the outlined
button beside Send or Alt+Enter, and every say no running turn can read —
lands on the log the moment it is said (`_sayLater` — the log is the queue)
and dispatches when the room settles. The composer names what is on offer:
an empty field while the agent speaks shows Stop; anything typed shows Send,
and the queue button beside it where the say would steer — the room's
`steers`, asked rather than copied, since only the room knows who is
speaking. Where the say lands after the settle already read the
queue — the turn was finishing while it was typed — `_sayLater` dispatches
it itself rather than waiting for a settle that already happened. A say
whose members are named schedules them through the same ordering anything
else takes. Under relay the settle part of that rule shrinks to the
member's: a say dispatches while the room is still busy, and the per-lane
check is what keeps a say for a busy member on their FIFO.

### Steering a turn

**Send over a running turn steers it.** `_steer` hands the say to the
running turn it addresses — Athena's for a say naming nobody, a member's
for a say naming that one member — through the turn's `SteerInbox`, and the
composer shows it in a strip above the field until the turn reads it
(`ChatViewState.steering`). It is not on the log yet. The agent takes the
inbox at each step boundary after a step that ran tools, never before the
first (the prompt has just gone), and reports each say as a `SteerEvent`;
the recorder writes it into the reply as a `SteerPart`, and the projection
words it as a user message after the results it arrived behind
(`steerTurnText`). So the parity holds: the live session and a reload build
the same messages from the same parts. Anthropic folds it into the
tool-results message, which is what Claude Code does too.

**Inside the reply, not a message of its own.** A message between the
turn's halves would split one reply in two in the log, and the turn, its
`turnEnd`, Continue and Regenerate all treat a reply as one message. The
cost is that regenerating the reply drops what was steered into it, and
another participant's view of the reply (`_saidText`) does not include it.

**What the turn never reads is queued after it.** A reply with no tool
calls ends the turn without another step, and so does the step limit; at
the turn's true end `_endTurn` closes the inbox and lands what is left as
queued says, ahead of anything sent while it closes. They dispatch at the
settle like any queued say, or stay on the log unsent where the round was
stopped. A `!` command, a say naming several members, or one whose
addressee is not speaking is queued from the start. The strip's buttons are
`queueSteer` (send it after the turn instead) and `withdrawSteer` (take it
back into the composer, its files read back from the chat's `resources/`
where sending saved them and deleted there, ahead of anything typed since;
a resend saves its own). The voice screen has no composer to take a say
back into, so its strip offers only the first.

A mirror sends the queue flag with the prompt (`SyncPromptSend.queue`); an
older home device ignores it and queues everything. The strip is the home
device's view state and is not sent, so on a mirror a steer shows nothing
until it lands in the reply.

**Abort stops the round whole.** Every running turn is ended `aborted`, the
queue of unsaid says is dropped, and the schedule is cleared — an aborted
round is a stopped one, and whatever the user says next is the first thing
of a new one. An interruption (`interrupt`, the app going away) does the
same to every turn but leaves the logs open, so each reply offers to be
carried on.

**Attribution rides the turn that asked for it.** Approvals, questions and
running sub-agents are keyed by the reply that raised them, so two turns
running beside each other hold their own banners; a finished turn's entries
leave with it, a sibling's kept. The status line and the retry row stay
page-level — they answer "is the turn alive", and there is one room on
screen.

**The lock is the room's rule, decided once.** What the lock once refused it
now queues (above), but the rule's shape is unchanged: `send` and every
driving verb it guards check `isRunning` and decide there — queue, dispatch,
or refuse. Who may speak now is decided in the room and nowhere else.
The renderings are consumers: the composer's button, the app-bar spinner,
the message row's editability, all reading view state.

**The room's phase is one answer, not a combination.** `ChatViewState.roomPhase`
says who may speak: `open` (composer is the user's), `agentSpeaking` (a turn
has the floor; an empty composer shows Stop), or `waitingOnYou` (a turn is
waiting on answers — the composer's place is taken by the question panel).
The third outranks the second: a turn waiting on answers is still running —
the spinner stays up, editing stays refused — but what it wants is the user.
`roomPhase` answers "who speaks", never "is a turn alive": surfaces about
the turn itself (the spinner, editability, the `ResumeBar`'s `unfinished`)
keep reading `isRunning`. Approvals are not a phase — they overlay an open
composer, and stay their own list.

## When a turn is over

`_finishTurn` drains the append queue and writes the `turnEnd` record before it
clears `isRunning`. Returning earlier would report a finished turn whose last
records are still in flight, and closing the app in that window would lose them
— and would leave a log that reads as killed when it was not. The window is
milliseconds on a disk. A write that fails still has to
clear the flag, or the composer stays disabled with nothing running.

**A background job's end can start the next one.** A job the agent started
outlives its turn, and when it ends with no turn running `_jobEnded` prompts
the room with the job's `<system-notification>` (`jobEndedNotification` in
`shell_job.dart`): the exit code and its log's tail, said by the app. It goes
through `_prompt` like anything said, so it is on the log as a user message
and a reload words it the same; the bubble draws a user message that is a
system notification as "System" rather than "You", and a steer that is one —
the plan's tasks-left note — as "Entoli, while it worked". A stopped job, a
job whose command the room never saw, and a job ending while a turn runs
start nothing: the running turn reads it on its next tool result.

## Automatic retry rounds

**A retryable failure is a blip the turn is carried on from, not an outcome.**
`ErrorEvent` says whether it was one — a connection that dropped, a provider
that hiccuped — and `_finishTurn` answers by re-entering `resume()`, the same
mechanism the Continue bar drives, up to the `turnRetries` setting (Off, or
1–10, default 5) with exponential backoff, 1s doubling to a 30s cap. The turn
stays `isRunning` across the rounds, the composer never flickers, and the
"Retrying (2/5) — connection lost" row is the existing `retry` view state doing
its job. When the rounds run out — or the failure was never retryable, a
rejected key or no model selected — the turn ends `TurnEnd.error` as it always
did, and the Continue bar is the way on.

The round is `_startResume()`, which is `resume()` without the guards: there is
one carry-on mechanism, and a retry that built a second one would drift from
it the way every second copy here has drifted. The round re-opens the reply
**its own turn** was writing — passed by id — not "the last assistant
message": under overlapping turns (relay, a parallel fan-out) a sibling's
still-streaming reply can sit below, and resuming by position would re-open
the wrong recorder. The user-facing Continue keeps the last-reply rule, an
open chat with one unfinished reply being what it offers to carry on.
`turnDone` stays open across
the rounds — a trigger awaiting it, or a voice handover, gets one completion,
at the true end, not one per attempt. A per-turn `retryGen` bumped by `abort` and
`interrupt` is what keeps a round waiting out its backoff from firing after
the user pressed stop: the wait holds nothing, and the generation is how it
notices the turn was ended behind it.

Each failed round writes a `turnEnd error` record the next round's supersedes
— last wins, the same bargain parts make — and the recorder replaces a
*trailing* `ErrorPart` rather than adding another, so five rounds leave one
error block in the bubble, not five. Nothing follows an error in a round's
stream (it closes after the event), so trailing-only is the safe shape of that
supersede. The recovery case keeps the failed round's error part: resuming
appends to the reply, and the log has no deletion — the same shape a
user-pressed Continue has always left. The Retry button under a reply reads
the same shape from the other side: it shows when an `ErrorPart` is
*trailing*, since that is "the last round failed"; asking "is any error part
in the reply" showed the button under every turn a round had been carried on
from, whose stale errors stay in the parts.

**And when the rounds run out with nobody looking, the app says so.** A turn
that ends `TurnEnd.error` while the app is hidden (the `appHiddenProvider`,
written by the app root's lifecycle listener) posts a notification on the
"turns" Android channel through `ReminderAlarms.notify` — the same tap
machinery the trigger completions use, chat id on the content intent, so the
tap opens the chat through the existing `IncomingTriggerOpen` path. Gated on
`headless` being false, since a fired trigger's new chat is already notified
by the manager that ran it — a second notice would be a double. Not gated on
anything per-chat: the user said the failure is visible enough when they are
*in the app*, even on another chat. On every platform without a notification
route the port is the no-op it always was, and the failure waits visibly in
the chat.

Reminder turns auto-retry too — they drive the same controller — which is the
point: a transient blip no longer fails a scheduled task. `MirrorChatController`
is out of this entirely; it runs no turns locally.

