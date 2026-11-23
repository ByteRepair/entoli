# The transcript

## Activities, on screen

What a reply is made of is the core's:
`packages/entoli_core/lib/transcript/`, which imports no widget. The UI
draws what it returns and decides nothing of what a row is. The layers, each
knowing only the one below:

- **The kinds** (`activities/`). `Activity` is one stateless class per kind: a
  tool run, a thinking block, an instruction read, a permission answered, an
  artifact or skill card. It answers `important` (does it stand on its own row),
  `node` (what it is on screen) and `detail` (what is behind it), as data, read
  through a `SettingReader` (`packages/entoli_core/lib/transcript/reader.dart`)
  — the drawing widget's ref — so what changes while a turn runs, a job's state
  or the plan, is watched by whoever draws it. `follow` is how an open detail
  re-reads its message as the turn runs: a tool run by its call, a thinking
  block by where it sits. **How a tool's calls look is its `ToolActivity`**: the
  node and detail, what voice mode says of a call (`spoken`, null for nothing)
  and the approval banner's glyph and question. `toolActivityFor` gives every
  other name the defaults ("Used x", "Allow x?"). `BashActivity` sets the
  command apart with the exit code under it, labels it with the call's
  `description` where the model gave one (see "The command's label" in
  `lib/data/builtin/AGENTS.md`), and is the job once a call started one
  (`JobActivity`); `TaskActivity` is a `SubAgentActivity`, whose detail holds
  the sub-agent's own transcript; the web tools show the query or URL.
  `JobActivity` and `SubAgentActivity` hold what they are drawn from, so a
  running pill opens the same detail with no call in hand. A call is matched by
  the name the log recorded, never by what this device offers; a test checks
  every `ToolActivity` names a tool the registry has.
- **The nodes** (`activity.dart`). A sealed set, each a kind of *drawing* rather
  than a kind of activity: `LabelNode` (the one muted line, a thought's tail
  streaming under it), `DiffNode` (a small write or edit as its lines),
  `PlanNode`, `OutputNode` (a card for what the turn made). A node knows its
  activity and run, and what pressing it opens: `node.open(handOff, source:)`
  goes through the UI's `TranscriptHandOff` — the plan's page for a `PlanNode`,
  the artifact or skill for an `OutputNode`, and otherwise an `OpensDetail`,
  whose `detail(reader)` is the `ActivityDetail` — title, glyph, command,
  status, sections, actions, and a sub-agent's `NestedTranscript`. A running
  pill opens the same way (`Opens`), so nothing switches over what a press
  opens. A `PlanNode` carries the plan as the file has it and its progress line,
  read where the node is built. A new node kind is a compile error until it is
  drawn. Glyphs are `TranscriptGlyph`s, which the UI maps to its pictures.
- **The layout** (`message.dart`). `MessageLayout.blocks(reader, moment)` is
  what `_rows` used to decide in the bubble: a `BubbleBlock` (its tint, files,
  what was said, what trails it — the spinner with its line, a running
  command's output, Retry), an `ActivityBlock`, an `ActivityRunBlock` of two or
  more unimportant activities behind one toggle, a reply's file, a `!` run, a
  steer. The caret-or-spinner rule, what breaks a run, and who the message
  says spoke (`Speaker`) are all here.
- **The rows** (`transcript.dart`). `Transcript.of` walks the thread into
  `MessageRow`s and the lines between them — the mode flips, a compaction's
  divider, a goal's mark (`GoalRow`, whose label and detail are the core's
  too) — each under a `key` stable across a streamed delta.
  `MessageActions` is what can be done to a message and does it: the
  threads and the steps between them, delete and its question, edit,
  regenerate, react — every rule of when each is on offer.
- **Ports**, bound at the root. `view/transcript_bindings.dart` is the
  drawing's own: `ActivityCatalog`, which `TranscriptActivities` implements
  over every kind. The catalogue is bound rather than imported because a
  sub-agent's detail holds a transcript that is made of activities: the
  layout depends on the abstraction, and the composite stays acyclic. The
  Flutter side has the same composite one level up — a detail draws a
  `MessageBubble` — and binds it the same way
  (`nestedTranscriptViewProvider`).
- **The host** (`transcript/host.dart`). Everything the drawing reads of
  its chat goes through `TranscriptHost`: the view state, the plan, a
  sub-agent's live message, an agent's face, an attachment's bytes, a job's
  log, stopping a job, and where the workspace is. None of it reaches
  `lib/providers.dart`, so the drawing runs with no app behind it. The app's
  `AppTranscriptHost` maps it onto the chat providers;
  `lib/core/app_transcript_bindings.dart` binds it, the hand-off and the ports
  above, and is what `main` and the harness both spread. The shared-chat
  viewer binds its own (see `packages/entoli_share_viewer/AGENTS.md`).

**The UI** draws all of it in `view/chat/activity/`: `ActivityNodeView` switches
over the nodes (`nodes.dart`) and hands each press to the node. What a press
opens is the `TranscriptHandOff` that `transcriptHandOffProvider` builds over
the context of what was tapped — `handOffOf(context)`. Both hosts' are a
`PageHandOff` (`view/chat/activity/page_hand_off.dart`), which opens a detail
as an `ActivityCard` that follows its source while it is open
(`showActivityDetail`, `card.dart`), the plan and an artifact on their own
pages, and says what an open threw. The app's, `ContextHandOff`
(`lib/ui/chat/activity/context_hand_off.dart`), adds a file, a skill, the
agent's browser and the page a message is edited on (`editMessage`), so a
bubble's Edit shows exactly where `MessageActions.canEdit` says. `MessageBubble` keeps its public
shape and lays its message out through `MessageLayout`, re-laid only when it is
handed another message.

## Background jobs, in the reply

The `bash` call that started a job is drawn as the job (`JobActivity`, from
`BashActivity`), by its `JobState` from `ChatViewState.jobOf`: running, ended,
or lost. Running, the label says "Running in the background" and the drawer
has the command, "Running · pid" under the title, Stop beside the close
button, and the end of the log as it grows (re-read every half second while
the file changes). Ended, it says how, from the log's `jobEnded` call event
(see "The conversation log" in `packages/entoli_core/lib/model/AGENTS.md`),
with the last lines the chat kept and an Open log button to the whole log in
`TextFilePage`, disabled once the workspace no longer has the file and absent on
a mirror, whose workspace is elsewhere. Lost, it ended with the app, or on a
mirror, where only ends arrive, it is "not heard from". What marks a call as a
job is `ToolResult.jobId`, set where the job started: a call asking for the
background on a shell with none ran in the foreground, has none, and is drawn as
a call.
