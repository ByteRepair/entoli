# The conversation on screen

What the page draws is a fact about the room; the room itself — its turns,
its schedule, Omada's routing, retry rounds — is
`packages/entoli_core/lib/model/room/AGENTS.md`.

## What the turn's extraction kept

Where the turn's extraction kept something, the page says so: the backend's
note stream carries a line for the chat — "Kept N memories." — and a note for
any other chat does not reach this one, since the extraction ran for it. The
page subscribes for the chat's life and cancels the subscription on dispose.

## Replying to a passage

The selection menu offers **Reply** beside Copy, wherever Copy is. It hands
the composer the selection as a copy's plain half reads — markdown — and
clears the selection, the passage having gone somewhere. The composer draws
it as a card; the message sends it as a blockquote, a blank line either side
of it, because markdown reads a line straight after a `>` line as more of the
quote. A reply is quoted under its author's handle, `> @scout` and an empty
`>` line above the passage: the handle is an ordinary mention, which is what
routes the answer to them (see "The contract between direct and Omada chats"
in `packages/entoli_core/lib/model/room/AGENTS.md`); the user's own message
carries none. `Quote` (`model/quote.dart`) is that blockquote both ways.

**A card is one character of the field.** The encoding is the core's,
`EmbedText` (`lib/app/embed_text.dart`), which knows an embed only as its
markdown and whether it is a block; `ComposerController` is the Flutter field
over it, handing each `ComposerEmbed` a private-use code point and drawing it
as a `WidgetSpan`, so
the composer is still one `TextField` and everything it does — the `/` and
`@` menus, the shortcuts, paste, undo, the keyboard and its IME — carries on
across a card without being told about one: the caret steps over it,
Backspace deletes it, undo brings it back. A column of fields and cards was
the other design, and every one of those would have had to be taught to cross
a seam. Its `text` holds the characters; its `message` is what is sent, each
embed written out, and is what everything asking what the user is saying
reads. `message =` is the inverse — a paragraph a reader claims comes back as
its card — so a message taken back returns as it was composed. A new kind of
thing in a message is a subclass of `ComposerEmbed` and, if it should come
back, a reader.

Quotes are added at the end with the caret put under them, so what is typed
next answers the last; with nothing typed between, they stack a blank line
apart, a line left to answer the one above later. **Reply focuses the field**
— the one thing that asks the composer for its focus, since choosing it is
asking to write — because a caret left wherever it last was, or put down by a
click, lands beside the card: a card is most of the field. A card is laid out
as wide as its line, so what is typed beside one wraps under it, and `message`
sets a block apart with a blank line however the field had it.

**Reply types a real line break under the card**, and while nothing is typed
on that last line the field draws the break as an invisible word joiner
instead: an empty last line is laid out as tall as the line above it, the
card's. Why a joiner and not a spacer is on `ComposerController._lineUnder`.
A field's lines are held to
the text's height unless it is given a strut that is not forced, so the
composer gives one while it holds a card — and two more lines of height for
each, rather than scrolling the cards away under the line being typed.

## A command the user ran

`!` in the composer sends the message to the shell instead of the model, and the
composer says so from the bang alone: the hint becomes "Shell command", the
field takes the mono face and a terminal mark, the outline changes colour and
Send becomes Run. Drawn rather than only obeyed — `!` sends the message
somewhere else entirely, and nothing else on screen would say so before it is
pressed. The `/` and `@` menus are off inside one, since neither expands
there.

Where the command will run is drawn too: the shell is the chat's own and a
`cd` in an earlier command moved it, so a row over the field shows the
directory the shell is standing in, live off the shell's own report — and
where the shell has said nothing yet, worded in the guest's own vocabulary
where it has one (IshShell seeds and falls back through `guestRoot`; the
host path the session is keyed by is not where anything stands in the
guest). A tap copies the path out, since a path is one of the things the
user types at the command rather than one to re-derive.

The prompt is drawn as the command it is: no markdown, the mono face, and the
surface a code block sits on rather than the colour the things the user said are
in. It is an ordinary message underneath — the `!` is what `conv.jsonl` keeps —
so editing it or regenerating it re-parses to the same command.

The reply is a `ShellRunBubble` and nothing else: the output in a `CodeBlock`,
and under it what the command exited with. Unhighlighted, because output is not
a language and guessing one would colour a stack trace as though it were. A
command that printed nothing says so on the exit row, rather than leaving a
strip that reads as an answer cut off. What is behind all this is "Running a
command yourself".

## A goal, on screen

`/goal` is dressed as the callback it is, the one dress every callback shares;
what differs is the send button, which `callbackSendLabel` names from the
callback the core says is typed — "Set goal", "Pause goal", "Clear goal" — as it
names `/compact` "Compact". A label per callback, since a button saying
"Compact" over `/goal pause` was the dress claiming more than was true.

The goal shows twice. **Where it stands now** is the row above the composer —
`GoalStrip` — with its pause or resume and its clear, each sent as the `/goal`
command it is. **Where it moved** is a `GoalMarkRow` in the conversation for
each `goal` record, after the message it names: an activity label in the reply's
gutter, "Goal set: …", "Goal paused: …", "Goal met: …", and "Goal answered: …"
for a command that changed nothing, opening the same kind of drawer every
activity has. The drawer says the state the goal was left in, why — the user's
pause, the reviewer's verdict — and the goal prompt as the model was given it.
Off the log, so a restart draws the same rows and a rewind takes them away with
their message.

## The task list, on screen

The latest turn's `todo` list shows above the composer beside the goal's row —
`TodoStrip` — done over total and the core's `TodoWords.headline`, opening in
place to every task. It is the list the replies since the last prompt wrote
(`TodoList.ofLastTurn`), so a new prompt puts it away until that turn writes its
own — an old list left on screen would claim work the user moved past. A
finished list stays until then, saying it finished. Each `todo` call in the
reply is a label (`TodoActivity`) reading as the task it moved to, "Task 2 of 5:
…", opening to the list as that call wrote it; not spoken.

## A chat whose home device is elsewhere

`MirrorChatController` is the counterpart of `ChatController` for a chat being
mirrored from a paired device, and `TurnDriver` is what both implement so that
every widget between them — the composer, the turn surface, the question panel,
the approval banner — is the same widget at either end. One runs the turn; the
other sends it to the device that will. See "Driving a turn from the other
end" for what the home device takes and from whom.

`ChatPage` branches on `isMirroredChatProvider` before anything else, and the
two arms meet again at `_page`: same bar, same centred column, same
conversation. What differs is stated as arguments rather than as a second copy
— `editing` is the controller the message row acts through and is null for a
mirror this device does not hold, which takes the whole edit/regenerate/thread
row out with it; `banner` is a mirror's strip, a
full-width row under the title bar that the conversation scrolls beneath
rather than one laid over it, and `bottom` is a composer or a bar saying why
there is none. Written out twice, the mirrored copy had already lost the jump
button, the empty-chat starter and the running-turn spinner.

**A project that requires setup hides the composer until setup is run.**
`BuiltinProject.requiresSetup` is a general flag; `setupCompleteProvider`
checks a `.setup-complete` marker in the project's directory — and, on the
guests (Android and iOS), that a rootfs is picked, the same env check the
settings page's banner asks. Where it is
false, the session's `ComposerSlot` (`ChatSession.slot`,
`NewChatSession.slot`) is `ComposerNeedsSetup`, drawn as
the setup bar in the composer's place — as `ComposerViewOnly` is drawn for a
mirrored chat offline — with a button that opens Settings at the project's
category. The slot is decided once, in the core. The turn path no
longer creates the rootfs lazily; "Run Setup" owns the full lifecycle.

**A chat moved to another project reloads the controller, and the move
aborts a running turn first.** The controller is a cache of what it read
off disk — project included — so the sidebar disposes it on a move rather
than patching it: the next read comes back from the new project, and the
composer composes against the new project's library from the next message.
`ChatRepository.moveChat` aborts a running turn before closing the shell
and moving, since a turn still standing in the old directories would remake
them under the project it left. Messages already composed keep what their
`/skill` and `@agent` references meant when they were sent — the records are
on the message, not looked up per turn.

## What is running, on screen

`RunningStrip` is one row in `TurnSurface` above the composer. What is on it
comes from `runningSources` in `lib/app/running.dart`, a `RunningSource`
function per kind of thing a chat can have running — the browser's tab,
background jobs, sub-agents — each supplying `RunningThing`s: a label, the
group it is gathered under, and what it opens (`Opens`: an activity's
detail or the browser's tab), which opens itself through the UI's
hand-off. The strip knows nothing of what they
are; a new kind is a source added to the list. Things with no group stand
alone ahead of the groups, which is where the browser's tab goes. It has no
surface of its own; the pills are the row. It scrolls sideways, and a mouse
wheel over it scrolls it without Shift, claimed through the pointer-signal
resolver the way the browser card claims one. Each group ("2 background
tasks running") is closed by default, which a tap opens
to a pill apiece inside it and closes again; the group's own surface stays
around the pills, which slide in from its left edge at their own size as the
group widens, fading in. Open or closed is the strip's own state, not the
chat's. Every pill is a `RunningPill`, the browser's included.

A pill opens the same drawer its label in the reply opens, from the same
view: a sub-agent's follows the turn through `chatViewProvider`, and a
job's is the job's (below).

Jobs are not turn-scoped: a pill per job the chat is running (see
"Background jobs" in `packages/entoli_core/lib/agent/AGENTS.md`), gone when it
ends. They come from the room's `ChatViewState.runningJobs`, which a mirror
never fills, so a mirrored chat draws none.

## The agent's browser, on screen

The sidebar's spinner (and the project palette's) reads `busyChatsProvider`,
a turn running *or* a browser tab open: a chat whose browser is up is active
between turns, and with the browser hidden nothing else on screen says so.

`browserRunning` gives the first pill of `RunningStrip`, standing alone, for as
long as the chat has a browser tab open — which is not turn-scoped: the tab
outlives the turn that opened it, until the user or the idle timer quits the
browser. It reads the tab straight off `agentBrowserProvider` rather than
through the controller's view state, since the tab is the browser's, not the
turn's — through a provider over the tab's listenables, so the row rebuilds as
the page changes — and draws nothing on a mirrored chat, whose browser is on the
device it came from. The pill names the page's host; tapping it opens
`BrowserCard`, a dialog of the tab's screencast frames over its title and
address. A hidden browser is watchable through it, which is the point. It
listens again when the tab is reopened under it (`BrowserPage.opened`) and says
so when the tab closes.

The card is also the user's hands on the page: back, forward and reload, a
Quit for the whole browser (every chat's tab with it — it is one process),
and the frame itself as a viewport. A pointer event is mapped from the drawn
frame to the page's CSS pixels (the frame's size is the viewport's) and sent
as `Input.dispatchMouseEvent`; the protocol counts a double click, so the card
does. Moves go one at a time, the newest waiting replacing any older, so a
fast mouse does not queue stale positions behind a slow socket. Every key goes
to the page while the viewport has focus — Tab and Escape included, which
would otherwise move focus or close the dialog. A synthesized key runs no
editing command on its own, so a shortcut names its own (`selectAll`, `copy`,
`undo`; `browser_input.dart`), and paste is the user's clipboard inserted as
text, the page's clipboard not being theirs. Copy and cut go the other way:
the page's selection (`selectedText`, a focused field's first) is put on the
user's clipboard, and the key still goes to the page, whose own handlers are
all an editor drawn on a canvas has.

A right click opens the card's own menu — Cut, Copy, Paste, Select all — and
does not reach the page: Chrome draws its context menu nowhere the screencast
shows. A held finger opens the same menu. A wheel is claimed through the
pointer-signal resolver and scaled to the page's pixels; a trackpad's two
fingers arrive as a pan-zoom, not a wheel, and are sent as one. A finger is
not a mouse: a tap clicks and a drag scrolls, since a drag sent as a mouse
would select text instead. None of it is gated or told to
the agent: the user is the one doing it, and the agent's next call reads the
page as the user left it. It acts only on an open tab — input never starts a
browser.

`BrowserPrompts`, the bar across the whole width above the row, draws the two
private paths of "Signing in" in `packages/entoli_core/lib/agent/AGENTS.md`. A
sign-in the agent asked for is `CredentialPanel`: the fields, obscured where the
agent said `secret`, with autocorrect and suggestions off, and Sign in and
Decline. What is typed lives in the panel's controllers and goes from them to
`submitCredentials`, cleared when the panel goes. A browser the agent hid is its
`reason` as a full-width button that opens the card, and the pill reads "hidden
from the agent" either way; the card has the "Hide from agent" toggle and, while
hidden, a band saying so with "Give back to agent".

An upload the user is to choose for is `UploadPanel`, over the sign-in panel's
place: "Choose file…" opens `file_selector`'s picker (several files where
the page's field takes several), Upload hands the paths to `submitUpload`,
Cancel cancels. **A message sent while one waits cancels it**, in the
composer's `onSend` before the send: what the user said instead is their
answer, the page's chooser is cancelled as a dismissed dialog would be, and
the agent's call says so.

## A shared chat

Share (a chat's row menu, its settings page, and the Chat menu) makes the
chat a link: `https://share.entoli.byterepair.io/#<zip>`, the zip base64url in
the fragment, which a browser never sends to the server. The zip is a data
directory of that one chat — the stamp, `share.json` naming it, and the chat
under the default project — so unpacking it is `AppConfig.load` over a
directory like any other, and a link from an older build is brought up by
the migration chain (`packages/entoli_core/lib/store/chat_share.dart`).

**What goes is the conversation, never the setup.** `conv.jsonl` and the
sub-agents' transcripts always go; the state goes stripped to id, title and
dates and marked imported; `meta.json`, the project, the pin and the TTL are
the sharer's and stay. The system prompt, the tools and the profile were
never in the log. Everything else is picked: the chat's attachments, its
artifacts, and its workspace files.

**The dialog** (`share_chat_dialog.dart`) is framed as the project palette
is, search over every row, arrow keys and Ctrl+Space. **Chat Attachments** is
its first line, one box for every attachment, its list collapsed under an
arrow; a divider, then Artifacts by their card's title and the workspace by
path. A file `isShareIgnored` names — a secret by its name — starts
unticked and says why; a credentials or build folder is one unticked line,
not walked, and ticking it sends everything under it.

**Nothing is left out unseen.** The link is capped at `appLinkMaxLength`
(`packages/entoli_core/lib/model/link_bytes.dart`), the cap every link Entoli
makes shares, and what does not fit is shown before Share, not reported
after: the sections that would go are drawn in red, and
every tick moves it. A zip compresses each member alone, so the link's length
is the conversation's cost plus each ticked piece's, exactly — what is ticked
together is compressed together, once (`ChatShareSource.measure`, one
`compute`), and `shareFit` (`packages/entoli_core/lib/model/chat_share.dart`)
sums them. Share joins those compressed members as they are rather than
compressing again. A piece whose size alone is past what deflate could bring
under the cap is answered a bound past it, never read.
Whole sections go, the workspace first, then the artifacts, then the
attachments, since those are what the conversation shows; a conversation too
long alone disables Share. Share packs exactly what is ticked and not red. The
share sheet takes the link; Linux's would be a `mailto:`, so there it is copied.

**Taking one in** is `ChatShares.import`: a new chat under a new id, in the
project on screen, its workspace and attachments with it, opened. The zip is
unpacked to a temp directory and `ChatStore.importChat` takes it in —
renamed into place where the filesystem allows, its state saved through the
store and its `resources/` locked. Only what a share packs is unpacked: a
`meta.json` in a hand-made zip would otherwise set the chat's approvals and
sandbox. Two imports
of one link are two chats. An imported chat runs nothing: `ImportedBar` stands
in for the composer, saying anything in it could be malicious — drawn, like
the setup and offline bars, as a `StandInBar`, and on a mirror with no
buttons, since the home device enables it — its messages offer no edit,
regenerate or reaction, voice mode will not open on it, and
`ChatRepository._turnSettings` refuses a turn for it, since a resume, a
paired device or a trigger reaches a turn without the composer. **Enable
Chat** (`ChatEdits.enable`) deletes the workspace files that came with it first, so no command
runs over them; **Enable and Import** keeps them. An attachment that was not
shared is drawn as its box with a stop sign, and a turn reads past it.

The viewer, where the app is not installed, is `packages/entoli_share_viewer`.

## The chat page

One app bar, whichever layout it is drawn in. Narrow, the sidebar is
`ChatPage`'s own drawer rather than a shell's — two bars stacked was the app's
name over the chat's, saying nothing twice. **It names the chat, always**: the
title, the project, and the pin or the countdown. It followed the scroll
position at first — the mark and "Entoli" at the top of the list, the title once
past it — and that put the app's name where the chat's belongs for every
conversation short enough not to scroll, which is most of the ones being
started. The mark is still on the bar for the two places there is no chat to
name — the new-chat screen and a chat being read off disk.

**The bar grows with what it has to say.** Every line is counted, the title's
own included, and Material's 56dp toolbar is only the floor. Counting up from
the toolbar instead — on the grounds that one detail line fits inside it —
holds at the default text size and nowhere past about 1.2, since the title
scales with the line under it: an Android phone set to a large font was
clipping the countdown off a chat that had nothing else to say. Counted rather
than measured — a bar that sized itself to its text would have to lay the text
out to know its own height, and a `Scaffold`'s `appBar` has to answer that
before it is built — which makes the count a thing that can drift from what is
drawn. So it is not a second list of conditions: `_details` is the only place
they are written down and `_barHeight` counts what it returned. Every row is
then *held* to the number counted for it rather than measured against it —
`_TitleLine.height` for a detail line, `_titleHeight` for the title — so what
the bar adds for a line is what the line takes, at any text scale, and the
count cannot drift from the draw. Nothing is padded: the sum is the height.

The conversation is a column of `readableWidth`, centred. A phone gets the
whole screen and a monitor gets a line that can be read back to the start of.
The composer is inside that column rather than under it: a centred conversation
over a full-width field is a field twice the width of what it is answering.

**Nothing selected is a new chat.** There is one empty screen rather than two,
and it is `_NewChat` — what is missing is the first thing to say, and the
composer to say it in is already under it. The pane that used to stand in front
of it offered New Chat, New Voice Chat and Open Chat, and all three had become
the same thing said twice: New Chat was a button that led to a page whose only
content was somewhere to type, the voice one is the composer's own circle, and
Open Chat is the drawer the bar already opens.

**And it is only a screen.** Nothing is created to stand behind it: no chat, no
`ChatController`, nothing on disk. The project is `selectedProjectProvider`'s
and the settings are `_NewChat`'s own, and `startChatWith` spends both on a
`createChat` at the moment the first message is sent — or, for a paired
device's project, asks that device to make it (see "A paired device's project,
while it is open" in `lib/data/sync/AGENTS.md`). So a screen
nobody typed into leaves nothing, which is the property this has to have, and
it gets it by choosing *when* to create rather than by holding something unsaved
— see "Starting a chat, and naming it" for the eleven branches that bought.

What that removes is a whole class of question. There is no draft to be at one
end of `ChatPage`'s three arms, so nothing has to make a chat during a build,
or after a frame, or exactly once while `AppShell` remounts the pane across
`navBreakpoint` — the one-at-a-time guard on `startNew` existed for that
remount alone. There is nothing to draw while it happens, so no blank frame
that reads as a page which could not load. And **switching project no longer
touches the pane**: `selectProject` writes a provider the screen watches, so
the badge redraws and the composer keeps what is in it, where before the screen
was torn down and rebuilt around a fresh draft.

The sidebar's New chat button and the assistant gesture are `openNewChat`,
which selects nothing and closes the drawer. Every other `select(null)` —
switching project, deleting the open chat, deleting them all — lands here too,
and now means what it says rather than "and quietly make one".

**Voice mode keeps the same rule**, and there is no exception left anywhere in
the app: `startVoiceChat` opens the page on no chat and `VoiceController` makes
one when it hears the first word, so a session nobody spoke in leaves nothing
either. What that cost is written up in "Taking turns" — the session had to
stop being keyed on the chat to be able to exist without one.

The two places that create, then, are the two that have something to put in a
chat: `startChatWith`, holding a message, and the voice controller, holding an
utterance. Both go through `SelectedChatId.create`, which is a method on the
notifier rather than a function beside the widgets for a plain reason — a
`Notifier` has a `Ref` and no `WidgetRef`, and the voice controller is one.

There is no exception for a paired device either: with one of its projects
picked, nothing selected is the new-chat screen for that project, its question
and starters that device's, and the first message asks the device to make the
chat.

`NewChatSettingsPage` (`chat_settings_page.dart`) is the settings of a chat
that does not exist yet: the model, the approve mode, the sandbox, the memory
switch and the TTL, which are values and need nothing to hang on. Save hands
a `ChatMeta` back rather than writing a file, and the new-chat session holds
it until `createChat` spends it. Its `ChatSettingsDraft` edits a copy, so a
page backed out of leaves the screen with what it had.

**A page of its own rather than a mode of `ChatSettingsPage`** — the two
share their rows through `ChatSettingsFields` — and the session's state
rather than a provider, both for the same reason. Folded into the chat's own
page it was null checks through a page whose subject ordinarily exists; and
held in a provider the settings outlive the screen, staying armed to land on
whatever chat is created next, in whatever project.

A chat's own page adds what a chat on disk has: its id, its workspace, the
context (`ContextPage`, a card per participant with one bar of what fills
its window) and Delete. Delete closes the pages over the chat first, and
works where the chat has no `state.json` to read. A failed Save says so and
leaves Save to try again. A mirrored chat's page leaves off what is its home
device's — the model, the sandbox, the workspace — is not saved while the
device is away, and is read again when it comes back.

`_EmptyChat` is the body of both empty screens — `_NewChat`'s, and a chat that
exists with nothing said in it yet, which is what voice mode and a trigger can
leave. It draws the mark, the question, the projects as badges, and a chip per
`/skill` and `@agent` the library holds. The chips are discovery: the composer's
menus are the only place those are named, and nothing names them until the
character that opens one has been typed, so a user who does not know they exist
never finds out. Everything the library holds is offered: everything the user
has written is a menu and `/` is what opens the menu, and the screen scrolls, so
nothing is held back to keep the page short. A paired device's project offers
that device's library, through `promptLibraryOf` like its menus; its badges are
left off, since they name this device's projects.

**The row is off until it is asked for**, by the switch in Settings > General >
Appearance > "Show command chips in start page" — `showCommandChips` in
`settings.json`, false by default and written only when on, the way `autoUpdate`
is written only when off.

**Both rows are `ChipRow`s** (see "Shared UI" in `lib/ui/widgets/AGENTS.md`),
which is why nothing here snaps when the set changes: picking a badge grows
its check, the row re-flows around the growth, and a badge pushed onto a new
line glides there rather than teleporting — that case is why the position
mechanism paints rather than wraps. A change of project swaps the starters
per chip — what both sets share keeps its slot, the delta grows out of
nothing or shrinks into it — and with nothing at all in the library the
"Type / for commands, @ for agents." line is an entry of the same row, so it
gives way to the first chips through the same motion. The question headline
sweeps between its projects' texts: the new question takes over from the
first character and the change front moves progressively towards the end,
over 400ms at constant speed, starting from whatever is on screen so picking
another badge mid-sweep retargets rather than jumps — where two strings
agree nothing visibly changes, so what moves is the divergence toward the
end.

**The screen opens settled.** It used to be that the rows animated their
first build too — the screen was grown into, not shown settled — and what
that bought was a page the user opens on that moves before anything has been
touched. So both rows are built `settled`: what this screen is created with
is already there, and everything from the first interaction on animates. The
same body serves a chat that exists with nothing said in it yet — what voice
mode and a trigger can leave — and it opens settled the same way. A remount
across `navBreakpoint` rebuilds the rows, and they open settled again, which
is right: that remount *is* the screen appearing. The say-so is scoped to the
row's first build, so content that is not on screen at that moment — a cold
start whose project list resolves a frame later — arrives the way any change
does: animated.

Under this device's badges, and only on the new-chat screen, sit **the paired
devices' badges** (`paired_project_badges.dart`): for each device that has
listed its projects, a `ConversationSeparator` line naming it (with
"· offline" while it is away), then every project it listed as a `ChoiceChip`
— its default included, a project there rather than nothing selected. They
come from `remoteEntries`, the sidebar switcher's own list. Ticking one is
`selectProject`; unticking it is this device's default. This device's badges
stay on screen whichever device is picked, unticked, so there is always a way
back. All of the projects sit above the `/`-`@` chips, so a pick changes only
what is below it and nothing above moves. They are `_EmptyChat`'s only under
`showSyncedCards`, which `_NewChat` alone passes: a chat that exists with
nothing said in it yet has no business listing other devices under its
question.

What the headline says is `emptyChatQuestionProvider`: a built-in's shipped
question, else the project's `description` (the settings page's Description
row, its dialog saving an empty field as empty and its reset button the way
back to null), else the app-wide default — and the provider answers one
string, null and empty both meaning "nothing to ask" by the time it returns.
Empty is a value the sweep can be handed — the label stays on the tree and
eats its own tail away rather than leaving it — so setting a description
never unmounts the headline, and the next question's arrival is a change,
not a mount.

The badges are the same discovery for projects: the switcher at the top of the
sidebar is the only other place one is named, and on a phone the sidebar is a
drawer. Picking one is `selectProject` — the switcher's own action, lifted out
of `_ProjectMenu` so that nothing that switches projects can come to disagree
about what switching means. Deleting one goes through it too. **The badge is
where the project changes**, and on this screen that is the whole of what
happens: `selectProject` writes the provider, the row redraws, and there is no
chat to take along or leave behind. Which badge is picked out is the open
chat's own project where there *is* one, rather than
`selectedProjectProvider` — so on a chat that exists the row says where this
conversation is, and on the new-chat screen it says where the next one goes.

**The default project is nothing selected**, and so has no badge. It is not a
project beside the others — it is the absence of one, which is what `null`
already means everywhere else it is written down. A `Default` badge would say
otherwise, and would be a thing to press to get back to where the app opens.
Pressing the selected badge is that instead, which makes the row a set of
toggles rather than a set with one always down.

The built-in projects have badges, and they are always on offer: `everyProject`
leads with them after the default, so a user who has never made a project sees
the built-ins alone rather than nothing. What the row names for one is its
label, not its directory — `Anon`, not `anonymous` — the same rule the
menus and the title bar keep. A built-in's badge carries its icon as the chip's
avatar, and the sidebar's project menu shows the same icon beside the label; a
user project has neither, since only a built-in ships one.

Tapping one types it into the composer through `insertCompletion`, which is the
field's own insertion lifted out of its `State` so both callers reach it — it
sits beside `CompletionField` in `ui/widgets/`, which is the composer's menu
now that the trigger editor writes a prompt too. Both halves of that mattered.
**Where** it lands is a rule: a skill goes to offset 0, because
`prompt_library.dart`'s `_skillReference` is anchored there and
`activeCompletionToken` gates `/` on `start == 0` — appended at the caret it
would be text that looks like a skill, dispatches as none, and is not even
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

The back key takes two halves, and a `Drawer` only brings one. An open one puts
a `LocalHistoryEntry` on the route it sits in, and a route holding one answers a
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
`ModalRoute` consults its pop entries *before* `LocalHistoryRoute` gets a say,
so the scope does reach `popDisposition`, and the `doNotPop` it forces is what
makes the notification claim. After that the claim is all of it: the press comes
in, the route declines to pop, and `onPopInvokedWithResult` closes the drawer by
hand.

This shipped broken once, and why is worth more than the fix. A widget test
presses back through `handlePopRoute`, which calls the framework directly and
never consults the platform — so the missing half was exactly the half the test
could not see, and it passed against a build that closed the app on a phone.
Anything asserting about the back key needs `frameworkHandlesBack` beside the
press.
