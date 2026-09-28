# Omada: the goal

Omada (Greek for "team") makes the project's agents **conversation
participants**. In an Omada-on project, an agent is not a sub-agent called by
another agent; it is a member of the chat, addressed by `@mention`, who authors
its own replies as turns on the record. The user talks to the team, the team
talks to each other, and the log says who said what.

This is Buzz (github.com/block/buzz) in Entoli's terms: agents as members with
identity and authorship, not bots bolted on the side.

## What it is not

- **Not a prompt convention.** Asking one model to role-play several agents, or
  to delegate via `task` with a nudge, gets collaboration but not
  participants: sub-agent output arrives as a tool result inside the parent's
  turn, one anonymous voice quoting its workers, and nothing on the record
  names who spoke. Omada is a structural change to turns, not wording.
- **Not a new agent format.** A member is the existing `agents/<name>.md`
  (a system prompt). Names are the `@` handles. No roster, no second list.
- **Not a second feed.** A member turn's tool activity renders as that reply's
  own labels — the same spine a reply has always had. There is no separate
  activity surface to build.

## The room

A chat is a room. `ChatController` owns it; the scheduling policy — who
answers a message — is decided once in `_memberAnswering`, and the room's
phase is one derived answer (`roomPhase`), not a combination each consumer
assembles.

- **The user** speaks through `TurnDriver.send` — every way a reminder or a
  voice utterance speaks goes through the controller's `send` too, one path
  rather than one per caller.
- **The main agent** is behind the event stream. In a direct chat every turn
  is its turn; in an Omada chat it answers what no member was addressed for.
  Its replies carry an "Entoli" label in Omada-on sections, so the mixed-mode
  history always says who spoke.
- **Sub-agents** (the `task` tool) exist only in direct chats: delegated
  participant turns, headless and off the record, their output readable by the
  main agent alone. In an Omada-on project `task` is not offered — members
  are brought in by handle.
- **Members** are the project's `agents/<name>.md`, addressed by `@mention`.
  Omada-on, a message addressing exactly one member is answered by that
  member as a participant: their prompt, their session, their reply on the
  record with their name on it.

## The contract between direct and Omada chats

**A direct chat** — Omada off — is strictly 1:1 between the user and the main
agent: every turn is the main agent's, `@mention` is instruction material, and
delegating happens through `task`, headless and off the record. Nothing
stamps, nothing labels, nothing hands off. Nothing separates the first
exchange from a chat that never heard of Omada.

**An Omada chat** adds the promotion route, and everything Omada does hangs
off it: member answering, stamps, labels, sections, handoffs. Turning Omada
off ends promotion for every turn after it; what is already on the record
stays — history is fact.

## The rules, borrowed from Buzz

- **Mention is addressing, deterministically.** `@name` in a user message
  resolves into `Message.documents` when the message is composed, before any
  model call. One mention routes one turn; several mentions stack several
  member prompts on the same turn until rounds replace that. Prose is not
  addressing — no fuzzy scanning, no inference.
- **Authorship is total.** Every member-authored reply carries its author in
  the log. A reload draws the same faces.
- **The label means a member authored the turn.** `Message.author` is stamped
  only where a member actually answered — never where the main agent merely
  used a member's instructions. The main agent's voice names itself "Entoli"
  in Omada-on sections; a direct chat's is unnamed.
- **Members are visible to each other.** When member B takes a turn, member
  A's earlier replies reach B labeled as A's words (projected as user-role
  messages prefixed with the author, per the projection's parity rule), never
  as B's own assistant turns.
- **Loops are capped.** Members may hand off to each other, but the round
  stops at `omadaMaxGenerations` dispatch waves of agent-to-agent work (the
  user's message is generation zero and uncapped) until the user speaks —
  the user's next message resets the count. A member can decline with the
  single word `pass`, on the record.
- **Sections, not a mode switch.** The room's Omada state at every turn is
  stamped on the turn's opener (`Message.omadaOn`), and a flip draws a
  separator ("Omada is turned on" / "Omada is turned off") above the turn
  that opened the new section. Labels are constant — nothing hides history —
  and sectioned: only on-sections carry stamps, labels and handoffs.

## What shipped

- **My Team, the Omada base** — a built-in project (`my-team`) with Omada on
  and the room contract for its note. It does not replace Default; it stands
  beside it as the base Omada prompt data derives from, the way user
  projects derive theirs from the default project: a user project with Omada
  on runs under My Team's note and inherits its members, the project's own
  entries and AGENTS.md above them. The chain is default < My Team < any
  other Omada project.
- **Settings** — the per-project toggle, the ordering dropdown, the italic
  marker, the built-in spec flag, `omadaOnProvider`.
- **Direct chats defined** — the 1:1 contract above, written into
  `lib/ui/chat/CLAUDE.md`; the author stamp gated on Omada.
- **Authorship** — `Message.author`, stamped by the controller when the turn
  opens: the one member a single `@mention` addresses. The label reads it;
  sync carries it; old logs read as null.
- **Member answering** — `TurnSettings.omadaMember`; the turn runs under the
  member's prompt from the library as it stands now, in a session of its own
  (keyed per member, rebuilt from the log), worded by the per-viewer
  projection: each participant reads their own replies as assistant messages
  and every other participant's as labeled user messages. The house reads
  member replies labeled too.
- **Sequential rounds** — the room schedules: `_schedules`, one FIFO per
  member, filled from user prompts (their mention lists) and from handoffs
  (the replies that name members). Sequential ordering dispatches one item
  at a time, the mention list the schedule; parallel dispatches one per
  member at once, each writing its own reply. A reply naming exactly one
  member schedules that member's turn; the round caps at
  `omadaMaxGenerations` dispatch waves (project override, app default ten);
  `pass` declines — and ends what agents hand each other, not a schedule the
  user made.
- **Relay — fully parallel handoffs.** The third ordering, beside sequential
  and parallel: dispatch gated on the per-member FIFOs alone, a handoff
  evaluated the moment the turn that named it finishes, waves overlapping.
  One turn per member still stands; the cap and `pass` work as in the other
  orderings; one member failing still stops the round.
- **Sectioned display** — `Message.omadaOn` on turn openers; separators at
  flips; "Entoli" on the house's replies in on-sections. The conversation
  renders as typed entries (`entriesOf`), each row owning its alignment.
- **`task` retired in Omada-on projects** — `AgentCapability.task` joins the
  disabled set, so the tool vanishes from the list and the prompt together;
  the room contract is My Team's bundled note, resolved in the repository
  (see `lib/ui/chat/CLAUDE.md`, "The room contract is My Team's note"). Direct
  chats keep `task` and the sub-agent machinery intact.
- **Phase C2 — flow control.** The settle-first handoff wave, send-while-
  running dispatching between turns (no mid-turn injection, protecting the
  projection-prefix invariant), the composer's empty-Stop/typed-Send rule,
  abort killing the whole round, per-turn attribution of approvals and
  questions, and the app-level ordering default. The recorder kept its
  one-reply-per-turn shape: the assumption lives in the per-turn instance,
  which is what lets two replies grow beside each other.

## What remains

- **Triggers, later.** What else may start a member's turn (schedule, file
  change) now that rounds exist.

## Design invariants carried

- **One accumulation, per viewer.** What a running turn puts in front of the
  model and what a reload rebuilds are one function, per viewer; parity is
  tested.
- **`conv.jsonl` is the log, never rewritten.** Sections derive from stamps
  on messages — a field has no order to get wrong; there is no separate
  marker record.
- **Omada-off is byte-identical to before.** No stamps, no labels, no
  markers, no capability changes; the full suite is the regression net, with
  explicit direct-chat tests pinning each surface.