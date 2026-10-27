# The conversation on screen

What the page draws is a fact about the room; the room itself — its turns,
its schedule, Omada's routing, retry rounds — is `lib/domain/room/AGENTS.md`.

## What the turn's extraction kept

Where the turn's extraction kept something, the page says so: the backend's
note stream carries a line for the chat — "Kept N memories." — and a note for
any other chat does not reach this one, since the extraction ran for it. The
page subscribes for the chat's life and cancels the subscription on dispose.

## Thinking and tool runs

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

**The spinner says what it is waiting for.** A spinner on its own cannot be told
apart from a hang, and against a model running on the device that wait is
minutes rather than seconds — so `StatusEvent` carries a line for the row it
sits on and `ChatViewState.status` holds the latest. It is one row, so the last
thing said replaces the one before it, and trouble wins it outright: a
`RetryEvent` beside "Thinking" would be the turn claiming to be fine while it is
not. The wording is the agent loop's rather than this layer's, because what is
worth saying differs per provider and per tool and only the loop knows which it
is waiting on. Against a local model it is a real percentage — see
`LlmPromptProgress`, and "How much context" in `lib/data/local/AGENTS.md`;
against everything else it is "Thinking" until the first token, which is the
whole of what is knowable there.

While a reply is still being written it ends in a `StreamingCaret`, which is
the other half of what the spinner does — the spinner answers for a turn that
has said nothing yet, the caret for one that has. The status goes when the caret
arrives, for the same reason: two things saying the turn is alive is one too
many. It goes on the last text part
**only when that part is the last part of the message**: text with a tool call
under it stopped arriving before the call started, so a caret left there points
at nothing while the label below is what is actually busy. It is a `WidgetSpan`
so that it sits after the last word rather than under the paragraph.

**A running tool label carries its own spinner** where the message has already
said something, since the spinner below the message is gated on `!hasText` and
a turn that says "Let me check that" before calling `bash` has text. The
`ToolLabel` gets `running: true` only for the live label of a waiting turn that
has text, so the two spinners never double up: the message-level spinner handles
the no-text-yet case, the label-level spinner handles the has-text case.

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

**A running command's output streams under its label.** While a `bash` call
(or the user's own `!` command) is printing, the tail of what it has printed
is a block in the trailing state, under the spinner row — the block is only
the output, the spinner the turn already carries being the whole of the
running indication, two of them being one too many. It is `ShellOutputEvent`
turn-scoped view state like the spinner, keyed by the reply rather than drawn
on the last message, since a message said while the command runs becomes the
last one: gone the moment the pair completes
(the label's drawer is what a finished command's output is behind) or the turn
ends, and never written to `conv.jsonl`. What a `!` bubble draws once its turn
is over is the ordinary `ShellRunBubble`, which is why the block does not
hand anything over — the part lands and the reply is no longer empty.

A run of two or more non-important activity labels collapses behind a single
centered "Expand activities" toggle (`ActivityGroup`), default collapsed. What
is important and so stays visible, breaking a run: an artifact button, a failed
tool run, an `ask_user` question, an instructions record (`InstructionsLabel`,
the first reach of an `AGENTS.md` — rare by construction, once per file), and
the live label a running turn is working
on. Text, errors and files are not labels and break a run too. A lone label is
left where it is — a toggle for one label is noise. The decision is per-part in
`_rows` (buffer into a pending run, flush at any break), and the length check
lives at flush time so a run is never half-collapsed. State is per-run and
in-memory: `ValueKey`ed on the run's first part index so a per-delta rebuild
keeps the same expanded/collapsed state, but a reload starts collapsed the way
every fresh view does.

**A label is muted, not small.** Body-sized type in `onSurfaceVariant`, no
weight, a 16pt icon and a faint chevron saying it opens, on a 34dp row: the
12pt label tier on a compact button read as squeezed against the reply, and
the colour and weight alone are enough to keep a label quieter than anything
said. One line, ellipsised — the label names what happened, the drawer says it.

**A thought streams where it is being written.** While a block is live its
last few lines run under the "Thinking…" label, faded at the top, and go when
it closes. Only the tail is laid out, since that is all that is shown and the
whole message rebuilds per delta.

The drawer opens at six tenths of the screen and grows with what is in it to
the whole of it; sized to its content alone, a one-line output was a strip at
the bottom of the window. On a wide window it is 960 wide rather than
Material's 640. It is a route, so the back key closes it and nothing had to be
written for that.

**And it streams.** A label is the wrong thing to hold an open drawer's
content: it is rebuilt per delta, folded into a collapsed run when its block
closes, and gone when the list scrolls past it. So the chat page puts an
`ActivitySource` above each message — a `select` of the chat's own view state
down to that message, its running command's output and whether a turn runs —
and a label hands the drawer a `follow` that re-reads its part from it: a
thinking block by its index, a tool run by its call id. While what it follows
is live the drawer says so beside its title, ends in a caret, and keeps to
the end the way the conversation does (`ScrollFollow`); a running `bash`
shows what it has printed so far as its output. With no source above — a
bubble pumped alone — the drawer is what it was opened with.

**A `task` drawer draws the sub-agent's own transcript** under the prompt, as
a `MessageBubble` — the same labels a reply has, opening drawers of their own.
`subAgentTranscriptProvider` follows it off the repository, or off the hub for
a mirrored chat, the way `chatViewProvider` picks its controller; it lives as
long as the drawer is open. The bubble sits under its own `ActivitySource`
(`subAgentLiveProvider`), so a label inside follows the sub-agent rather than
the parent's reply. It is live while the transcript's log is open and its chat
runs a turn, since a log left open by a killed process is not a run going on.
Where there is no transcript the drawer shows what the call returned instead.

### Selecting a reply, and copying it

The **message** is one `SelectionArea`, with one `SelectionContainer` under it
and nothing between that and the fragments — heading, paragraph, list item,
code block — so a drag runs from the first paragraph to the last, and copy
answers from the same fragments the highlight is drawn from. The per-part
container this replaced built a region to itself per text part, which is what
stopped a drag at the paragraph it started in; `MarkdownBody(selectable:
true)` is worse still, a `SelectableText` per element. The container delegate
is held on the bubble's state rather than per build: a streamed delta rebuilds
the message every frame, and a delegate per build would drop the selection
under the drag that is making it.

The region is around all of `_rows` rather than inside `_bubble`, and that is
the whole point rather than a detail: `_rows` closes the bubble at every
reasoning part and every tool call, so a region per bubble would have stopped
the drag at the first tool label — which is most of the replies this app
makes. It also cost a `SelectableRegion` per bubble on every streamed delta,
since a message is one list item and rebuilds whole.

What that puts inside the region is the labels, which are not what the message
said, so each is wrapped in `SelectionContainer.disabled` — dragging past one
must not put "Thought for 12 seconds" on the clipboard. The `SelectableText` in
a label's drawer is on its own route, so nothing nests.

What a selection copies is **the rendered text, the words on screen** —
`_RenderedSelection` answers `getSelectedContent` from each selected fragment
and joins the blocks with a newline, so Ctrl+C, the context menu and the
mobile toolbar all write exactly what is highlighted. The newline is the one
thing the base delegate does not answer: the gaps between blocks live in
widgets, not in text, so the framework's own answer glues a heading to its
paragraph. What is not text contributes nothing — an image and anything a
custom element builder drew is outside the fragments — and selection can also
not cross messages, one region per message as ever.

**A copy carries its formatting too**, so a word processor pastes headings,
bold and lists rather than flat words. Flutter cannot do this alone: the
selection API answers in plain text only, and `Clipboard.setData` sends one
string to an embedder that writes it as `text/plain` — so overriding the
selection decides *what* is copied, but only `setRichClipboard`
(`core/platform/rich_clipboard.dart`) can write it with an HTML entry beside
it. That is a channel, `agent_chat/clipboard`, answered by a few lines in each
runner (GTK targets, `NSPasteboard`, `UIPasteboard`, `ClipData.newHtmlText`,
`CF_HTML`) and by `navigator.clipboard.write` in a browser; a runner that does
not answer gets the plain text. The Apple halves sit in `MainFlutterWindow` and
`AppDelegate` rather than files of their own, which would want an Xcode
project entry this host cannot make.

The region's own copy writes plain text, so both ways in are taken over: Ctrl+C
by an `Actions` above the `SelectionArea` (the region's copy action is
overridable, and defers to it), and the menu's Copy by `_selectionMenu`, which
does what the framework's item does after it. Both read the selection before
anything is awaited, because the menu clears it.

What the HTML says comes from two places, since a fragment knows neither alone
(`selection_html.dart`). The **spans** under the selected range say what was
bold, italic, code or a link — the fragment type is private, so its paragraph
is found by the transform both report and the text it indexes. The **markdown**
says what kind of block each paragraph was (`RenderedOutline`, keyed by the
paragraph's text): a list item, a cell, a heading, a quote — which the spans
cannot, a list item and a paragraph being drawn alike. A code block or table
under a scroll is a selection container of its own rather than a fragment, so
it copies as its text, a code block as `pre`. The copy button needs none of
this and renders the markdown whole (`formattedHtmlOf`), escaping HTML the
model wrote the way the screen shows it.

What can be done to a message is a row under it rather than a menu, uncovered by
hovering the message or, where there is no pointer to hover with, by touching
it. Left to right: which thread this is and the arrows between them, copy,
raw copy, delete, then Edit and Regenerate. **Copy takes the formatted text**
(`formattedTextOf`, in `lib/domain/formatted_text.dart`, parsed with the same
grammar the renderer reads, so the two cannot disagree about what a fence is)
— what a reader would paste into
another document, and the same answer at message scale the selection is,
formatted beside it as above.
**Raw copy (`<>`) takes the markdown**, every text part and no thinking — the
same rule a rewound session is seeded by — and the Edit field reads that too,
since editing the rendered text would not resend to what produced it. Copy is
offered only where something was said, since a message of tool calls alone
would copy nothing. The counter and the arrows are there only where there is
more than one thread — `1/1` and two dead arrows say nothing — while delete
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

### How a reply is set

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
`LicenseRegistry` lazily — so the licence page under About has it, which is what
reads that registry. Bold is bundled beside regular because inline code inherits
the weight of what holds it, and a heading with a `` `name` `` in it is a shape
this app's replies take constantly.

### Code blocks

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

`CodeBlock.span` is optional, and omitting it is how a caller says there is
nothing to highlight — a `!` command's output is not a language, and guessing
one would colour a stack trace as though it were. The block then asks the same
cache, so it gets the plain span *and* gets it back identical on every rebuild,
which is what a caller assembling its own per frame would have thrown away.

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
bubble keep: a drag across the reply copies the rendered text, and the
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

### A command the user ran

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

### A compact turn, and its divider

`/compact` is a callback, not a prompt: the composer dresses for it (an
`auto_awesome` icon and a "Compact the conversation" hint — lighter than the
shell's dressing, since nothing runs on the machine and no model is asked), the
send dispatches it before the room's guards, and while a turn runs it is
**refused, not queued** — a callback mid-turn is the session the turn is
rewriting underneath it. The turn itself goes through the room's machinery:
prompt logged as said, empty reply, the status row saying "Compacting the
conversation" where a model's spinner would be, `turnEnd done`. Its product is
the marker, not a reply.

**The marker is a `ConversationSeparator`** — the same full-width divider the
Omada mode flips are, generalized to take a caption and furniture beneath the
line — emitted by `entriesOf` just after the boundary message it covers,
captioned "Compact Conversation". The summary is rendered beneath it in
`MessageText`, the widget a reply's text is encoded in — the same markdown,
code blocks and link taps, in the gutter a reply keeps, always visible,
nothing to tap. It is not selectable: the divider is metadata, and a selection
container of its own is the per-row container the bubble's single region
replaced. Auto-compact
leaves the same trace with no turn around it: unawaited after a settled turn,
the divider its only evidence, the way the memory extraction's note is.

## Tools, on screen

**How a tool's calls look is its `ToolUI`** (`tool_ui/`), the UI's half of
the tool's class: what voice mode says of a call (`spoken`, null for
nothing), the approval banner's icon and question, whether its label stands
on a row of its own (`prominent` — a question, the plan put to the user), and
the label itself, null for the generic `ToolLabel`. One class for each tool
that shows anything of its own; `toolUIFor` gives every other name the
defaults ("Used x", "Allow x?"). The bubble, the banner and the voice
transcript ask it rather than switching on names.

A call is matched by the name the log recorded, never by what this device
offers, so a mirrored chat or an old one draws the same. A label whose
content changes while the turn runs watches its own provider, as `PlanLabel`
watches `planProvider`; the `ToolUI` itself holds no state. A test checks
every `ToolUI` names a tool the registry has, since the two are paired by
that string alone.

## The plan, on screen

A `present_plan` call is drawn as the plan it put to the user (`PlanLabel`):
every task with whether it is done, each opening to its details as markdown.
It is not a slim activity label, since the plan is what the turn stopped to
show. The bar carries a checklist button beside the running-turn spinner for
as long as the chat has a plan, and it opens `PlanPage`, the same list with
the progress over it.

Both read `PLAN.md` off the chat's workspace through `planProvider`, not off
the call: the card shows where the work stands now, ticks included. The
provider reads again when `planRevision` moves — a result landing for a plan
tool or a `write`/`edit` — rather than watching the file, since every write to
it lands in the conversation as one; a `bash` that rewrote it is picked up at
the next. A mirrored chat's plan is asked of its home device over the sync
channel (see "Attachments" in `lib/data/sync/AGENTS.md`), so the same card and
page draw it at either end.

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
false, `_NewChat` and `_local` swap the composer for a `NeedsSetupBar` —
the same full-swap pattern `ViewOnlyBar` uses for a mirrored chat — with a
button that opens Settings at the project's category. The turn path no
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

## Background jobs, on screen

`JobStrip` sits in `TurnSurface` under the browser chip and, like it, is not
turn-scoped: a pill per background job the chat is running (see "Background
jobs" in `lib/data/builtin/AGENTS.md`), gone when the job ends, since the
agent hears how it ended. It reads the backend's list directly, not the
controller's view state, and draws nothing on a mirrored chat. A pill opens
`JobSheet`: the command, the pid, and the end of the log as it grows (re-read
every half second while the file changes), with Stop. A sheet left open when
its job ends keeps the last of the log and loses the button.

## The agent's browser, on screen

The sidebar's spinner (and the project palette's) reads `busyChatsProvider`,
a turn running *or* a browser tab open: a chat whose browser is up is active
between turns, and with the browser hidden nothing else on screen says so.

`BrowserStrip` is a chip in `TurnSurface`, below the running sub-agents and
drawn the way their strip is, for as long as the chat has a browser tab open
— which is not turn-scoped like the strips above it: the tab outlives the
turn that opened it, until the user or the idle timer quits the browser. It
reads the tab straight off `agentBrowserProvider` rather than through the
controller's view state, since the tab is the browser's, not the turn's, and
draws nothing on a mirrored chat, whose browser is on the device it came
from. The chip names the page's host; tapping it opens `BrowserCard`, a dialog
of the tab's screencast frames over its title and address. A hidden browser
is watchable through it, which is the point. It listens again when the tab is
reopened under it (`BrowserPage.opened`) and says so when the tab closes.

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

The strip also draws the two private paths of "Signing in" in
`lib/data/builtin/AGENTS.md`. A sign-in the agent asked for is
`CredentialPanel`, above the chip: the fields, obscured where the agent said
`secret`, with autocorrect and suggestions off, and Sign in and Decline. What
is typed lives in the panel's controllers and goes from them to
`submitCredentials`, cleared when the panel goes. A browser the agent hid is
its `reason` as a button that opens the card, and the chip reads "hidden from
the agent" either way; the card has the "Hide from agent" toggle and, while
hidden, a band saying so with "Give back to agent".

An upload the user is to choose for is `UploadPanel`, over the sign-in panel's
place: "Choose file…" opens `file_selector`'s picker (several files where
the page's field takes several), Upload hands the paths to `submitUpload`,
Cancel cancels. **A message sent while one waits cancels it**, in the
composer's `onSend` before the send: what the user said instead is their
answer, the page's chooser is cancelled as a dismissed dialog would be, and
the agent's call says so.

## The chat page

One app bar, whichever layout it is drawn in. Narrow, the sidebar is `ChatPage`'s
own drawer rather than a shell's — two bars stacked was the app's name over the
chat's, saying nothing twice. **It names the chat, always**: the title, the
project, and the pin or the countdown. It followed the scroll position at
first — the mark and "Entoli" at the top of the list, the title once past it —
and that put the app's name where the chat's belongs for every conversation
short enough not to scroll, which is most of the ones being started. The mark is
still on the bar for the three places there is no chat to name — the new-chat
screen, a chat being read off disk, and a paired device's list with nothing
picked out of it.

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

The conversation is a column of `_readableWidth`, centred. A phone gets the
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

The one place nothing selected is not a new chat is a paired device's list,
which `ChatPage` checks first: a new chat is this device's and takes the sidebar
home with it, so picking a device would bounce straight back off it. That arm
says to pick a chat, and is now a peer of the new-chat arm rather than an
exception to it — neither writes anything.

`NewChatSettingsPage` is the settings of a chat that does not exist yet: the
model, the approve mode, the memory switch and the TTL, which are values and
need nothing to hang on. Save pops a `ChatMeta` back rather than writing a
file, and `_NewChat` holds it until `createChat` spends it. It edits a copy,
so a page backed out of leaves the screen with what it had.

**A page of its own rather than a mode of `ChatSettingsPage`**, and `_NewChat`
state rather than a provider — both for the same reason. Folded into the chat's
own page it was five null checks and two `!`s through a page whose subject
ordinarily exists, which is the shape this change spent its effort removing
from the repository; and held in a provider the settings outlive the screen,
staying armed to land on whatever chat is created next, in whatever project.
The three fields are already standalone widgets, so the page that composes them
is thirty lines.

`_EmptyChat` is the body of both empty screens — `_NewChat`'s, and a chat that
exists with nothing said in it yet, which is what voice mode and a trigger can
leave. It draws the mark, the question, the projects as badges, and a chip
per `/skill` and `@agent` the library holds. The chips are discovery: the
composer's menus are the only place those are named, and nothing names them
until the character that opens one has been typed, so a user who does not know
they exist never finds out. Six at most, because everything the user has
written is a menu and `/` is what opens the menu; with nothing at all in the
library it says how to reach them instead. A paired device's project offers
that device's library, through `promptLibraryOf` like its menus; its badges
are left off, since they name this device's projects.

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

**The chapter rail** (`ChapterRail`) is a tick per prompt in the margin right
of the column, the one being read picked out, the first line of each on hover.
It is laid over the margin rather than beside the column, so the column stays
centred whether it is there or not, and it is drawn only where the margin has
room for it — `_ReadableColumn`'s `side`. A chapter is a prompt and the turn
under it, so a branch anywhere in that turn — an edit at the prompt, a
regenerate under it — puts a fork beside its tick (`chaptersOf`, off
`Chat.branches`). A steer is a chapter too, with a tick of its own: it is
something the user said, and a long steered turn would otherwise be one tick
with every steer in it. It has no row of its own — it is a part of the reply
— so a `Chapter` carries the `row` it is in as well as its `id`, and going to
one goes to the reply's row and then to the steer's bubble, keyed through
`MessageBubble.steerKey`. What it draws is fed from the chat's view state, not
assigned while the page builds: a `listenManual` with `fireImmediately` hands
it the chat as loaded, then every change — a turn, a deletion, a thread
switched — and restarts when the chat id changes, since `_ChatBody` is not
keyed per chat and its state outlives a switch. The tooltip is the prompt's
first line, cut at fifty characters. **A press selects, not a tap**, and so
does every move while pressed, so dragging a mouse or a finger along the rail
scrubs the conversation prompt by prompt; a scrub jumps where a press
glides. That is one `Listener` over the whole rail finding the tick by
height, not a handler per tick — a pointer stays with what it went down on,
so a tick's own handler never hears the drag reach the next. The rail does
not scroll, since a drag on it is a scrub; its ticks close up instead when
there are more than fit. Which one is being read is the last prompt at or above the
top of the view, read after the frame rather than in the scroll listener: a
jump reports before the list has laid out the rows it moved to. Going to one
detaches the turn's follow, since no gesture said so.

**The list is a `SuperListView`** (`super_sliver_list`), not a `ListView`. A
`ListView` sizes itself from the rows on screen, so its extent changed with
every row scrolled in: the scrollbar thumb resized and jittered, and the
offset corrections near the top showed as jumps. The `ListController` keeps an
extent per row, measured once a row is laid out, and `_MeasureAll` measures
every row up front, a frame's budget at a time, for conversations short enough
that it matters. Going to an unbuilt prompt used to jump to a one-height-per-row
guess and animate from there, which could land below the view and run back up;
`_glideTo` instead lerps from where the view is to the sum of the extents above
the row, read again on every tick as rows are measured on the way, and lands
with `jumpToItem`. One `AnimationController` drives every glide, so a second
press takes over the first, and a pointer down or wheel on the list stops it. A
row laid out at a height other than the one measured for it moves the view
under the glide, and the glide carries that move rather than undoing it on the
next tick. Landing on a steer whose bubble is built goes straight to it: going
by the reply's row first showed the reply's top for a frame.

A chat opens at its latest message. `_settleAtBottom` jumps and then jumps
again until the extent stops moving: a builder lays out only what shows, so the
extent any one frame reports is an estimate and a single jump lands short of the
end. **Jump to latest goes through it too**, after its glide — the extent it
read when the button was pressed was that same estimate, so on its own the
button left the reader a little above the last message, by an amount that
depended on how tall the messages happened to be. Not
`reverse: true`, which would land at the end exactly and for free — in a
reversed viewport the offsets of older messages shift as the newest one grows,
so a reader scrolled up during a turn would watch the text move.

A turn follows itself only while the reader has not scrolled away from it —
`ScrollFollow` (see `lib/ui/widgets/AGENTS.md`), not a position test. The old
test was per tick: every delta arriving while the reader dragged back through
a turn pulled the view down again, so a scroll up inside `_slack` snapped
back more often than it stayed. Now any gesture toward the older messages
detaches — however small, however near the end it stops — and reaching the
end again by any means attaches. Outside the follow the list is left alone —
the offsets of earlier messages do not move as the last one grows, so reading
back through a turn is undisturbed — and a button appears to go back down.
Its own `_slack` decides only the button: it turns up once the view is past
200px off the end. Both edges are `ValueNotifier`s, since a `setState`
mid-drag would rebuild every visible bubble to swap a title or a button.
