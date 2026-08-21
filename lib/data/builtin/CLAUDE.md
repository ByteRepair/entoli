# The agent loop

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
the marker without writing answer text, leaving the sub-agent runner with
nothing to hand back. Upstream still holds the opposite rule — a reply with no
tool call
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

## Running the commands

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

### Running a command yourself

A message that starts with `!` is a command, and `BuiltinBackend._runBypass`
runs it and ends the turn. No model call, no tools, no approval — the user typed
the command, so there is nobody to ask and nothing to classify. The check comes
before the model is resolved, which is what makes `!ls` work in a chat with no
provider configured at all. It is the shell the agent uses, in the same
workspace and under the same `commandTimeout`, and Stop kills it:
`_RunningTurns` holds a stop callback rather than a `BuiltinAgent`, so a
command's `kill` and an agent's `cancel` are the same thing to it.

`shellBypassCommand` in `domain/shell.dart` is the whole of the syntax, and it
lives there rather than beside `_command` and `_mention` because five places
read it: this, the composer, the bubble, `suggestTitle` and `endsUnfinished`. A
bare `!` is a command too — an empty one — so the composer can say what it is
about to do from the keystroke that decides it rather than a word later.

What the turn writes is one `ShellRunPart`, holding the command and the outcome
together. Deliberately not a `ToolCallPart` and its result: nothing called a
tool, and a model reading the conversation back would find itself having chosen
something it never did. The projection words it as an assistant message
instead — `shellRunTranscript`, which is `observation` with a sentence over it
saying who ran it — so the model sees the command and the exit code without
being told it made the call. As the user it would be two user messages in a row,
which not every provider accepts.

The live session is filled through `projectionOf`, which is by now what every
turn does — this one is unusual only in that the app wrote the reply rather than
a model. It gets the prompt message itself and builds the reply beside it, so
what the model is holding now and what a reload would build out of the log
cannot be two different conversations. The reply it builds carries no id,
because the projection does not read one; everything it does read — the date, an
attachment's bytes, what a `/command` stood for — is on the prompt, which is the
message being logged. See "The projection".

An aborted `!` turn writes nothing — no part, and nothing into the session
either. The command was killed, so whatever it had printed is not an answer.

**Two things outside this file ask the same question**, and both would otherwise
send a command to a model. `endsUnfinished` never offers a `!` turn to be
carried on, whatever cut it off: resuming appends to the reply, and a command
has nothing to append — the only way to continue one would be to run it again.
And `ChatRepository.suggestTitle` names nothing from one: a command is not a
thing said, and titling it is a model call on the one turn the user routed away
from a model, in a chat that may have no provider at all.

## Approvals

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

## Questions

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

Every call is reported and every call is answered, which is the invariant that
keeps the next turn from being rejected — but nothing here answers one. A turn
reports its result and the projection words it, so the report is the answer;
`_ran` is only the ShellResult a command hands back, said as the result of the
call that asked for it. See "One accumulation".

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

## Sub-agents (the `task` tool)

`task` spawns a sub-agent with its own session under the named `@agent`'s
prompt, runs it to completion headless, and returns its final text as the tool
result. That text is read off the session when the run ends rather than
collected from the deltas as they stream — the session is the sub-agent's whole
transcript, so one carried on after an interruption answers with both halves,
which is what the single `task` call that asked for it is owed. Collecting the
deltas answered with the half after the interruption, and the empty-buffer
fallback underneath it reached into the session and answered with the half
before; which of the two you got turned on whether the second half said
anything. See "One accumulation". The sub-agent shares the parent's model,
shell, and workspace, but
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

### Their own transcripts

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

### Carrying one on

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

## Web search (the `websearch` / `webfetch` tools)

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
