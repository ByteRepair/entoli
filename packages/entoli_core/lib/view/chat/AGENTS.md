# The conversation on screen

What the page draws is a fact about the room; the room itself — its turns,
its schedule, Omada's routing, retry rounds — is
`packages/entoli_core/lib/model/room/AGENTS.md`.

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
a turn that says "Let me check that" before calling `bash` has text. A run's
label's `Run.going` is true only for the live label of a waiting turn that
has text, so the two spinners never double up: the message-level spinner handles
the no-text-yet case, the label-level spinner handles the has-text case.

**Never both**, and that is one decision in `_rows` rather than two that happen
to agree. Asked separately they did not: the spinner's question was
`Message.hasText`, which trims, so a turn whose first flush was a blank line had
said nothing by that test while its last part was already a `TextPart` — a
spinner and a caret at once. `liveAt` is the same consolidation a level down,
since "the part this turn is working on" was being spelled out for the caret and
again, with a clause on the end, for a thinking block's `Run.going`.

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

A run of two or more non-important activities collapses behind a single centered
"Expand activities" toggle (`ActivityGroup`), default collapsed. What is
important and so stays visible, breaking a run, is what an activity's
`important` says — an artifact or skill card, an `ask_user` question, the plan
put to the user, a permission answered, an instruction read (the first reach of
an `AGENTS.md`, rare by construction, once per file), the thinking block being
written — and, for every kind, a run that failed and the call the live turn is
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

The drawer opens at six tenths of the screen and grows with what is in it to the
whole of it; sized to its content alone, a one-line output was a strip at the
bottom of the window. On a wide window it is 960 wide rather than
Material's 640. It is a route, so the back key closes it and nothing had to be
written for that. It is drawn after the app's dialogs — their surface, a
headline title, a status line under it, actions beside the close button, and
output in code blocks (`codeBlockDecoration`) — while keeping a drawer's layout
of labelled sections, since it is swiped or tapped away where a dialog is not.
`ActivityCard` is that drawing, whoever feeds it: a thinking block's drawer and
every run's. A `bash` drawer sets the command apart as a `!` message is, keeps
what else the call was given as its Arguments, and says the exit code in the
status line.

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

The **message** is one `RichSelectionArea`
(`packages/entoli_core/lib/view/selection/`): a `SelectionArea` with one
`SelectionContainer` under it and nothing between that and the fragments —
heading, paragraph, list item, code line, formula — so a drag runs from the
first paragraph to the last, and copy answers from the same fragments the
highlight is drawn from. The per-part container this replaced built a region to
itself per text part, which is what stopped a drag at the paragraph it started
in; `MarkdownBody(selectable: true)` is worse still, a `SelectableText` per
element. The container delegate is held on the area's state rather than per
build: a streamed delta rebuilds the message every frame, and a delegate per
build would drop the selection under the drag that is making it.

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

**Everything a copy of a selection is lives in
`packages/entoli_core/lib/view/selection/`**, behind interfaces, so the bubble
says only which markdown it drew. The pieces, in the order a copy passes through
them:

- `RichSelectionArea` owns the delegate (`RichSelectionDelegate`), Ctrl+C
  and the menu's Copy. The region's own copy writes plain text, so both ways
  in are taken over: Ctrl+C by an `Actions` above the `SelectionArea` (the
  region's copy action is overridable, and defers to it), and the menu's Copy
  by swapping that one item and doing after it what the framework's does.
  Both read the selection before anything is awaited, because the menu
  clears it.
- `SelectionReader` reads the selected fragments into a `CopiedDocument`:
  blocks of `CopiedText` runs, each with its marks and link, and
  `CopiedFormula`s. The selection API answers in plain text only, so it reads
  the drawn paragraphs themselves. The **spans** under a selected range say
  what was bold, italic, code or a link — the fragment type is private, so
  its paragraph is found by the transform both report and the text it
  indexes. A **placeholder** says where a formula sits. The **markdown** says
  what kind of block each paragraph was (`RenderedOutline`, keyed by the
  paragraph's words, a formula left out on both sides): a list item,
  a cell, a heading, a quote, which the spans cannot say, a list item and a
  paragraph being drawn alike. A block the app draws itself says what it is
  with a `CopiedBlockScope` — a code block, and which language it was fenced
  as — rather than being guessed at from its font.
- A `CopyFormat` writes the document. **`MarkdownCopyFormat` is the plain
  half**: an editor, a terminal or another markdown field gets the reply as
  it was written — heading marks, list markers, fences with their language,
  table pipes, quote marks, emphasis, code spans, links, and every formula as
  its TeX — rather than the words with the rest gone. **`HtmlCopyFormat` is
  the rich half**, so a word processor pastes headings, bold, lists and tables
  (styles inline, since it reads no stylesheet; a formula as a picture of
  itself, since none of them can typeset TeX — see below).
- `writeClipboard` is where it goes. Flutter cannot do this alone:
  `Clipboard.setData` sends one string to an embedder that writes it as
  `text/plain`, so it (`view/rich_clipboard.dart`) writes both through a
  channel, `agent_chat/clipboard`, answered by a few lines in each runner (GTK
  targets, `NSPasteboard`, `UIPasteboard`, `ClipData.newHtmlText`, `CF_HTML`); a
  runner that does not answer gets the plain text. The Apple runners write RTFD
  and RTF too, converted from the HTML by the system's own reader: Pages,
  TextEdit and Notes read those and not HTML, and without them pasted the plain
  half — which is markdown — as it stood. RTFD carries a formula's picture as an
  attachment, which RTF drops. The Apple halves sit in `MainFlutterWindow` and
  `AppDelegate` rather than files of their own.

What is not text contributes nothing — an image, and chrome wrapped in
`SelectionContainer.disabled` — and selection cannot cross messages, one area
per message as ever. An item picked up from the middle is its words, not an
item, since the bullet was not part of what was selected.

**A scroll inside the reply does not get a selection of its own.** A
`SingleChildScrollView` is a selection container, which made a code block —
and a display formula, which scrolls the same way — a block apart from the
selection crossing it: the scroll drew its highlight and handles, and what
it copied was its text alone. `SidewaysScroll` hands the registrar above it
straight through (`SelectionRegistrarScope`), so the lines inside register
with the message's container like any paragraph's.

**Inline code's background is translucent.** A paragraph paints its
selection highlight first and its text after, span backgrounds included, so
the opaque surface inline `code` sat on hid the highlight wherever it fell
(`inlineCodeStyle`).

**A formula is selected whole** (`SelectableFormula`): a drag that passes
most of the way over it picks it up and washes it in the selection colour.
Part of a formula is no TeX, and the glyphs are the maths library's own
drawing, not text a selection could take a range of. It follows the same two
rules as everything else: the plain half is the TeX as it was written,
delimiters and all, and the formatted half is **the formula as drawn** — a
PNG it draws of itself on copy (`FormulaDrawing`), from a repaint boundary of
its own so the highlight is not in it, at three times its size, and with the
theme's text colour recoloured black, since the page it lands on is white
whatever the app's theme. Only that colour: a `\textcolor` the TeX asked for
is what was meant, and pastes as it was drawn. Its TeX
is the picture's alt text. Drawing is asynchronous, so a copy reads the
selection on its first line and only then waits; `dragCopy` settles in real
rounds for the same reason.

A paragraph is matched to what registered for it by position and offsets,
not by its words: every `Text` registers through a container of its own,
which answers a formula as its TeX where the paragraph holds a one-character
placeholder — and `SelectableFormula` counts as one offset to match it.

The copy **button** is apart from all this: it renders the whole message's
markdown (`formattedHtmlOf`), escaping HTML the model wrote the way the
screen shows it, beside the formatted words (`formattedTextOf`); raw copy is
the markdown. Its formulas are the selection's pictures all the same
(`replyContentOf`, from every `SelectableFormula` the bubble drew), so a
formula pastes alike whichever way it was copied.

What can be done to a message is a row under it rather than a menu, uncovered by
hovering the message or, where there is no pointer to hover with, by touching
it. Left to right: which thread this is and the arrows between them, copy,
raw copy, delete, then Edit and Regenerate. **Copy takes the formatted text**
(`formattedTextOf`, in `packages/entoli_core/lib/model/formatted_text.dart`,
parsed with the same grammar the renderer reads, so the two cannot disagree
about what a fence is) — what a reader would paste into another document, with
its HTML beside it. A selection's plain half is markdown instead, since a range
is more often pasted where it was written; the button for that at message scale
is raw copy. **Raw copy (`<>`) takes the markdown**, every text part and no
thinking — the same rule a rewound session is seeded by — and the Edit field
reads that too, since editing the rendered text would not resend to what
produced it. Copy is offered only where something was said, since a message of
tool calls alone would copy nothing. The counter and the arrows are there only
where there is more than one thread — `1/1` and two dead arrows say nothing —
while delete is offered whatever the count, since deleting the last thread at a
point is the conversation being cut off there and is worth being able to do. The
arrows stop at either end rather than wrapping: one that comes back round to
where the reader started reads as having done nothing. Deleting asks first, and
the question says whether anything is left, because those are two different
things to be agreeing to.

The row keeps its height whether or not anything is in it, so the conversation
does not shift under the pointer the moment the icons appear. The reveal is a
`Listener` rather than a `GestureDetector`: a raw pointer listener sidesteps the
gesture arena, so one touch both starts a selection in the bubble and shows the
actions. It writes a `ValueNotifier` rather than calling `setState`, so
uncovering the icons does not rebuild the message's labels behind them.

### How a reply is set

**Markdown anywhere is `MarkdownText`** — a reply, a skill, a README, a
workspace file, a trigger's prompt, the privacy policy. It is the one place a
`MarkdownBody` is built, and it carries everything that makes markdown look
like the app's: the style sheet below, built once per theme rather than per
build (a new sheet re-parses the whole document); the code-block and formula
builders; `replyExtensionSet`, the grammar the copy reads; and the bullets,
drawn as chrome a drag does not pick up, numbered on a numbered list. A page
that built its own `MarkdownBody` got some of that and not the rest — the skill
pages had no code-block bar, and every page but one re-parsed on each rebuild.

`replyStyleSheet` is the whole of the look, and it starts from
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

A quote is a bar and nothing else: `outlineVariant` down its left, its text a
tone quieter than the reply's. `fromTheme` filled it and rounded it, and the box
shrank to its own text, so every quote was a slab of a different width, the bar
cut off at the corners, and a nested quote a box inside a box. The composer's
quote card keeps its fill, being a thing to remove rather than a passage read.

Prose is set looser than Material's 1.43, since a reply is read as prose in a
column where the line you want next is the one below. That goes to `p`,
`listBullet`, `blockquote` and `tableBody` rather than to `p` alone — the rule
is about the reply, not about the `<p>` element, and `fromTheme` hands all four
the same plain `bodyMedium`. A list is the shape a reply most often takes.

**Code is set in a bundled face**, and `view/fonts.dart` is the whole of what
Dart knows about it. `monospace` is an alias the platform resolves, so the same
reply was Roboto Mono on one Android, Droid Sans Mono on another and DejaVu on
this desktop — and the five things
this app shows verbatim (code, a tool's command and its output, a chat id, a
config value) are shown that way precisely because their characters line up.
Roboto Mono is the mono companion to the face Material already uses.

`monoFamily` and `registerBundledFontLicences` are in a file of their own rather
than in `view/theme.dart`, which owns the palette and could not read an asset if
it wanted to. Five facts have to move together — the `family` and the two `.ttf`
entries in the core's pubspec `fonts:` block, the `OFL.txt` asset, and those two
— so they are one file and one section here rather than scattered by proximity.

**Both faces are subset to Latin.** Text fonts are not tree-shaken the way icon
fonts are, so the full files shipped 876 codepoints of which nearly half were
Cyrillic, Greek and Latin-Extended, 148 KB gzipped. Subset it is 58 KB. Anything
outside the subset falls back to a system face, which is what already happened
to arrows and box-drawing: Roboto Mono has never had them. Regenerating, which
nothing automates:

```sh
uv tool run --from fonttools pyftsubset RobotoMono-Regular.ttf \
  --output-file=packages/entoli_core/assets/fonts/RobotoMono-Regular.ttf --layout-features='*' \
  --name-IDs='*' \
  --unicodes="U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,\
U+2000-206F,U+2070-209F,U+20A0-20BF,U+2100-214F,U+2190-21FF,U+2200-22FF,\
U+2500-257F,U+2580-259F,U+25A0-25FF,U+2713-2717,U+FFFD"
```

`--name-IDs='*'` is not decoration: it keeps the copyright and licence records
in the file, which is half of what the OFL asks for. The other half is
`packages/entoli_core/assets/fonts/OFL.txt`, an asset rather than only a file in
the repo, read into `LicenseRegistry` lazily — so the licence page under About
has it, which is what reads that registry. Bold is bundled beside regular
because inline code inherits the weight of what holds it, and a heading with a
`` `name` `` in it is a shape this app's replies take constantly.

### Formulas

TeX is drawn wherever `MarkdownText` is, by `flutter_math_fork` — KaTeX's layout
in pure Dart, its fonts bundled, nothing native. `$…$` and `\(…\)` set a formula
in the sentence; `$$…$$` and `\[…\]` set it on a line of its own, centred and
scrolling sideways when wider than the column, as a code block does.

The delimiters are read in `model/math_syntax.dart`, as markdown syntaxes
rather than a pass over the finished text, so nothing inside a formula is
taken for markdown first: `a_b_c` is not italics, and a line of a multi-line
formula starting `- ` is not a list. The block rule is there for that last
case. A `$` is maths only by Pandoc's rule — a non-space after the opening one,
a non-space before the closing one, no digit after it — which is what keeps
"$5 and $10" prose. The copy parses with the same syntaxes, so a formula
copies as the TeX it was written as, delimiters and all.

An inline formula is a `Text.rich` holding one `WidgetSpan`, because the
builder merges a `Text`'s spans into the paragraph and lays any other widget
beside it in a `Wrap`, which breaks the line around it. TeX the parser refuses
is shown as it was written. A formula is selected whole and copies as its
TeX; see "Selecting a reply, and copying it".

The renderer and the copy read one grammar, `replyExtensionSet`, beside
`parseReply` in `model/formatted_text.dart`. Parsed TeX is kept the way a code
block's spans are, and for the same re-parse on every frame of a cross-fade —
keyed on the TeX, since the tree carries no style, so a theme change keeps every
entry. **But a tree is drawn in one place at a time**: `flutter_math_fork` keeps
the widget it built on each node, an equation row's with a `GlobalKey` in it, so
one tree drawn twice fails layout and blanks the whole chat — which v7.3.0 did
to any chat with the same formula twice. So the trees are each `MarkdownText`'s
own (`MathBuilders`), never shared with another reply, and one per occurrence:
the second `$x$` is the second tree for `x`, counted from the first again at
every build. A wide display formula scrolls in `SidewaysScroll`, the code
block's own scroller, scrollbar and all.

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
and nothing tree-shakes an unnamed one, so all of them cost 359 KB gzipped
against 56 KB for these — measured, both. A fence naming
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

### A compact turn, and its divider

`/compact` is a callback, not a prompt: the composer dresses for it (an
`auto_awesome` icon, and the send button named for what the callback does —
lighter than the shell's dressing, since nothing runs on the machine and no
model is asked), the send dispatches it before the room's guards, and while a
turn runs it is **refused, not queued** — a callback mid-turn is the session the
turn is rewriting underneath it. The turn itself goes through the room's
machinery: prompt logged as said, empty reply, the status row saying "Compacting
the conversation" where a model's spinner would be, `turnEnd done`. Its product
is the marker, not a reply — and where no marker lands, the turn ends `error`
with "The conversation could not be compacted." and the backend's reason on the
reply, in an error part's red.

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

**An automatic compaction that fails is drawn too**, because failing without
a word is the worst way it can fail: `ChatViewState.compactFailure` holds the
reason, and the page appends a `CompactionFailedEntry` after the last
message — a divider captioned "Could not compact the conversation" with the
reason beneath it in `MessageText`'s error red. It is view state, not a log
record: the next settle tries again and says so again if it fails, a turn
opening clears it, and so does a marker landing.

## The plan, on screen

A `present_plan` call is drawn as the plan it put to the user (`PresentPlanUI`):
every task with whether it is done, each opening to its details as markdown.
It is not a slim activity label, since the plan is what the turn stopped to
show. The bar carries a checklist button beside the running-turn spinner for
as long as the chat has a plan, and it opens `PlanPage` (`plan_page.dart`),
the same list (`PlanTaskList`) with a progress bar over it.

Both read `PLAN.md` off the chat's workspace through the host's `plan`, not
off the call: the card shows where the work stands now, ticks included. In the
app that is `planProvider`, which reads again when `planRevision` moves — a
result landing for a plan tool or a `write`/`edit` — rather than watching the
file, since every write to
it lands in the conversation as one; a `bash` that rewrote it is picked up at
the next. A mirrored chat's plan is asked of its home device over the sync
channel (see "Attachments" in `lib/data/sync/AGENTS.md`), so the same card and
page draw it at either end.

## The scrolling list

**The scrolling list is `ConversationView`** (`widgets/conversation_view.dart`):
the list, the rail, the glides, jump to latest and the turn's follow, below.
It reads the chat's view state from the host (`TranscriptHost.view`, which in
the app picks the mirror's controller for a mirrored chat) and is handed how
to draw a message and what sits under it — the composer here, nothing in the
shared-chat viewer — so both draw one conversation and neither keeps a copy
of the scrolling. A link tapped in model-written markdown opens through
`linkOpenerProvider` (`openMarkdownLink`), which both hosts bind.
Sending calls its `follow()`.

**The chapter rail** (`ChapterRail`) is a tick per prompt in the margin right of
the column, the one being read picked out, the first line of each on hover. It
is laid over the margin rather than beside the column, so the column stays
centred whether it is there or not, and it is drawn only where the margin has
room for it — `ReadableColumn`'s `side` — from the first prompt on: a lone tick
still says where the conversation starts. A command the user ran is a chapter as
well, its tooltip the `!` line as typed, since it is something they did there. A
chapter is a prompt and the turn under it, so a branch anywhere in that turn —
an edit at the prompt, a regenerate under it — puts a fork beside its tick
(`chaptersOf`, off `Chat.branches`). A steer is a chapter too, with a tick of
its own: it is something the user said, and a long steered turn would otherwise
be one tick with every steer in it. It has no row of its own — it is a part of
the reply — so a `Chapter` carries the `row` it is in as well as its `id`, and
going to one goes to the reply's row and then to the steer's bubble, keyed
through `MessageBubble.steerKey`. What it draws is fed from the chat's view
state, not assigned while the page builds: a `listenManual` with
`fireImmediately` hands it the chat as loaded, then every change — a turn, a
deletion, a thread switched — and restarts when the chat changes, since
`ConversationView` is not keyed per chat and its state outlives a switch. The
tooltip is the prompt's first line, cut at fifty characters. **A press selects,
not a tap**, and so does every move while pressed, so dragging a mouse or a
finger along the rail scrubs the conversation prompt by prompt; a scrub jumps
where a press glides. That is one `Listener` over the whole rail finding the
tick by height, not a handler per tick — a pointer stays with what it went down
on, so a tick's own handler never hears the drag reach the next. The rail does
not scroll, since a drag on it is a scrub; its ticks close up instead when there
are more than fit. Which one is being read is the last prompt at or above the
top of the view, read after the frame rather than in the scroll listener: a jump
reports before the list has laid out the rows it moved to. Going to one detaches
the turn's follow, since no gesture said so.

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
`ScrollFollow` (see `packages/entoli_core/lib/view/widgets/AGENTS.md`), not a
position test. The old
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

Sending attaches, wherever the reader had scrolled to: what they said is the
latest. The viewport shrinking — the keyboard coming up — keeps a following
list at its end rather than leaving the end under the keys. And a touch drag
toward the older messages drops focus, which takes a soft keyboard down
(`KeyboardDismissOnScrollBack`); a wheel or a trackpad does not, so a
desktop's composer keeps its caret. The new-chat screen has no list to drag,
and iOS's keyboard no key to hide it, so a touch tap or a swipe down in its
empty space does the same (`KeyboardDismissOnTouch`).
