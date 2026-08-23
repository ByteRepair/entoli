# The conversation on screen

## When a turn is over

`_finishTurn` drains the append queue and writes the `turnEnd` record before it
clears `isRunning`. Returning earlier would report a finished turn whose last
records are still in flight, and closing the app in that window would lose them
— and would leave a log that reads as killed when it was not. The window is
milliseconds on a disk and longer on IndexedDB. A write that fails still has to
clear the flag, or the composer stays disabled with nothing running.

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
`LlmPromptProgress`, and "How much context" in `lib/data/local/CLAUDE.md`;
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

A run of two or more non-important activity labels collapses behind a single
centered "Expand activities" toggle (`ActivityGroup`), default collapsed. What
is important and so stays visible, breaking a run: an artifact button, a failed
tool run, an `ask_user` question, and the live label a running turn is working
on. Text, errors and files are not labels and break a run too. A lone label is
left where it is — a toggle for one label is noise. The decision is per-part in
`_rows` (buffer into a pending run, flush at any break), and the length check
lives at flush time so a run is never half-collapsed. State is per-run and
in-memory: `ValueKey`ed on the run's first part index so a per-delta rebuild
keeps the same expanded/collapsed state, but a reload starts collapsed the way
every fresh view does.

The drawer is sized by what is in it, up to the whole screen. It used to stop at
seven tenths of the height, which is a tool's output cut short and a third of the
screen left empty under it. It is a route, so the back key closes it and nothing
had to be written for that.

### Selecting a reply, and copying it

The **message** is one `SelectionArea` and the markdown inside it is not
selectable of its own accord. `MarkdownBody(selectable: true)` builds a
`SelectableText` per element, and each of those is a selection region to itself
— so a drag stopped at the paragraph it started in, which is the whole
complaint. Plain `Text.rich` under one region selects across the lot.

The region is around all of `_rows` rather than inside `_bubble`, and that is
the whole point rather than a detail: `_rows` closes the bubble at every
reasoning part and every tool call, so a region per bubble would have stopped
the drag at the first tool label — which is most of the replies this app makes.
It also cost a `SelectableRegion` per bubble on every streamed delta, since a
message is one list item and rebuilds whole.

What that puts inside the region is the labels, which are not what the message
said, so each is wrapped in `SelectionContainer.disabled` — dragging past one
must not put "Thought for 12 seconds" on the clipboard. The `SelectableText` in
a label's drawer is on its own route, so nothing nests.

What a selection copies is the **markdown that was rendered**, not the text it
rendered to: `_MarkdownSource` is a `SelectionContainer` delegate per text part
that answers `getSelectedContent` with the part's source. There is no finer
granularity available — the renderer keeps no source offsets, so there is
nothing to map a partial selection back through — so anything selected inside a
part copies the whole of that part. That is what puts `**bold**` on the
clipboard rather than `bold`, and it is why the copy button below is the same
answer at message scale rather than a second mechanism. The delegate answers
from `value.hasSelection` rather than from `super.getSelectedContent()`, which
would walk every selectable and concatenate what each holds only for the answer
to be thrown away.

What can be done to a message is a row under it rather than a menu, uncovered by
hovering the message or, where there is no pointer to hover with, by touching
it. Left to right: which thread this is and the arrows between them, copy,
delete, then Edit and Regenerate. Copy takes the message's `plainText`, which is
every text part and no thinking — the same rule a rewound session is seeded by.
It is offered only where something was said, since a message of tool calls alone
would copy nothing. The counter and the arrows are there only where there
is more than one thread — `1/1` and two dead arrows say nothing — while delete
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
bubble keep: a drag across the reply copies the markdown behind it, and the
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

## A chat whose home device is elsewhere

`MirrorChatController` is the counterpart of `ChatController` for a chat being
mirrored from a paired device, and `TurnDriver` is what both implement so that
every widget between them — the composer, the turn surface, the question panel,
the approval banner — is the same widget at either end. One runs the turn; the
other sends it to the device that will. See "Control, and driving a turn from
the other end" for the lock and what refuses what.

`ChatPage` branches on `isMirroredChatProvider` before anything else, because
almost none of the local page applies: no expiry check, no chat settings, no
edit or regenerate row, and nothing that would write to a disk this device does
not have. What control changes is only whether the composer is drawn.

## The chat page

One app bar, whichever layout it is drawn in. Narrow, the sidebar is `ChatPage`'s
own drawer rather than a shell's — two bars stacked was the app's name over the
chat's, saying nothing twice. **It names the chat, always**: the title, the
project, and the pin or the countdown. It followed the scroll position at
first — the mark and "Entoli" at the top of the list, the title once past it —
and that put the app's name where the chat's belongs for every conversation
short enough not to scroll, which is most of the ones being started. The mark is
still on the bar with no chat open, where there is no title to draw instead.

**The bar grows with what it has to say.** One detail line fits under the title
in Material's 56dp toolbar and two do not, so a chat that is both in a project
and temporary was having its countdown clipped. The lines are counted rather
than measured — a bar that sized itself to its text would have to lay the text
out to know its own height, and a `Scaffold`'s `appBar` has to answer that
before it is built — which makes the count a thing that can drift from what is
drawn. So it is not a second list of conditions: `_details` is the only place
they are written down and `_barHeight` counts what it returned. The per-line
number is `_TitleLine.height` and the row is *held* to it rather than measured
against it, so what the bar adds for a line is what the line takes, at any text
scale.

The conversation is a column of `_readableWidth`, centred. A phone gets the
whole screen and a monitor gets a line that can be read back to the start of.
The composer is inside that column rather than under it: a centred conversation
over a full-width field is a field twice the width of what it is answering.

With nothing selected the pane is the ways to have a conversation — New Chat,
New Voice Chat and Open Chat — over the project they happen in. The second is
an extension of the first rather than a third thing: it makes a chat and opens
it in voice mode, and it sits with New Chat rather than beside the way to open
an old one. Open Chat is the drawer, so it
is drawn only where there is one: beside a sidebar that is already out it would
open what is on screen. It asks the `Scaffold` above it rather than taking a
flag beside the one that built that Scaffold, since two answers to "is there a
drawer here" can disagree. New Chat is `startChat`, which the sidebar's own
button also calls, so there is one answer to what a new chat is and which
project it lands in.

Above them are the projects, as badges, and that is the same discovery
`_EmptyChat` does for commands: the switcher at the top of the sidebar is the
only place a project is named, and the sidebar is what this pane is drawn
instead of. Picking one is `selectProject` — the switcher's own action, lifted
out of `_ProjectMenu` so that nothing that switches projects can come to
disagree about what switching means. Deleting one goes through it too. **The
badge is where the project changes, not either button**: New Chat and Open Chat
act on what is already picked out, so pressing one is never also a choice about
where it lands.

**The default project is nothing selected**, and so has no badge. It is not a
project beside the others — it is the absence of one, which is what `null`
already means everywhere else it is written down. A `Default` badge would say
otherwise, and would be a thing to press to get back to where the app opens.
Pressing the selected badge is that instead, which makes the row a set of
toggles rather than a set with one always down.

So a user who has never made a project sees nothing here, which is right: with
none there is no choice to offer, and the row would be one badge that is always
selected and can lead nowhere.

A chat with nothing *said* in it is `_EmptyChat`, and it is a different question
— the chat is open, so what is missing is the first thing to say. It draws the
mark, the question, and a chip per `/command` and `@agent` the library holds.
That list is the point of it: the composer's menus are the only place those are
named, and nothing names them until the character that opens one has been typed,
so a user who does not know they exist never finds out. Six at most, because
everything the user has written is a menu and `/` is what opens the menu; with
nothing at all in the library it says how to reach them instead.

Tapping one types it into the composer through `insertCompletion`, which is the
composer's own insertion lifted out of its `State` so both callers reach it.
Both halves of that mattered. **Where** it lands is a rule: a command goes to
offset 0, because `prompt_library.dart`'s `_command` is anchored there and
`activeCompletionToken` gates `/` on `start == 0` — appended at the caret it
would be text that looks like a command, dispatches as none, and is not even
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

A chat opens at its latest message. `_settleAtBottom` jumps and then jumps
again until the extent stops moving: a builder lays out only what shows, so the
extent any one frame reports is an estimate and a single jump lands short of the
end. **Jump to latest goes through it too**, after its animation — the extent it
read when the button was pressed was that same estimate, so on its own the
button left the reader a little above the last message, by an amount that
depended on how tall the messages happened to be. Not
`reverse: true`, which would land at the end exactly and for free — in a
reversed viewport the offsets of older messages shift as the newest one grows,
so a reader scrolled up during a turn would watch the text move.

A turn follows itself only while the reader is already within `_slack` of the
end. Outside it the list is left alone — the offsets of earlier messages do not
move as the last one grows, so reading back through a turn is undisturbed — and
a button appears to go back down. The same slack decides both, so the button
turns up exactly when the view stops keeping up. Both edges are
`ValueNotifier`s, since a `setState` mid-drag would rebuild every visible bubble
to swap a title or a button.
