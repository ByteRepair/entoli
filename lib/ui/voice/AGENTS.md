# Voice mode's screen

## Reading one message out

The row under a message has a speaker button, and it is **not voice mode**: no
microphone, no recognition model, nothing said back into the conversation. That
is `recognition` being null on `Voice.start` — a session with nothing to listen
with — rather than a second port, since what it does is the half of a session
that already existed.

`ReadAloud` owns it, and owns exactly one thing being read at a time. The
preview beside the voice picker in settings goes through the same notifier
under the id `preview`, so the two can never talk over each other and a second
copy of the model is never loaded to do it. Voice mode is the third thing that
can speak and is *not* under it, so `VoiceController.start` stops it first: a
message still being read out when the composer's circle is pressed would be a
second speech model in a second isolate, and two voices at once. Both buttons
that read something out go through `readAloud`, which is `toggle` plus the
snack bar its failure needs — the notifier has no `Scaffold` to say it in,
which is why it answers with a string. The session is let go the moment
the message has been read — a speech model is a hundred megabytes of a phone's
memory to hold for a button nobody may press again — and what says it has been
read is the session falling silent, since nothing above it can tell generating
from playing.

The button stays up while it reads, uncovered or not: stopping must not mean
going looking for the button that started it.

## The screen

An orb of light, under the word for what voice mode is doing. It breathes on a
slow cycle while it listens and swells with the microphone on top of that,
sheds rings as it goes, orbits while a turn runs, beats as the reply is read
out, and sits dim and still while the microphone is shut — four looks to tell
apart across a room, which is the point of a screen nobody is looking at
closely. `VoiceBloom` decides what is running and `BloomPainter` draws it.

**The word is there because motion cannot say `starting` or `failed`.** It
replaced a Material glyph in the middle of the orb, which is a thing to decode
and was the only thing telling those two apart from listening. It is also the
semantics label, so what a reader hears is what is on screen.

**What a voice state looks like is the state's own business**, not each
widget's: `hushed`, `word` and `voiceColour` sit on `VoiceViewState` in
`voice_controller.dart`, because the orb, the dot beside the word and the Stop
button all have to agree, and the first version had the orb owning the four-arm
colour switch while the button re-derived one arm of it.

**Two controllers, and only because of the periods.** The rings and the orbit
are never on screen together, so they share `_cycle` and what a mode changes is
its duration; the breath is 1.9s against the rings' 2.9s and reading it off the
same controller would jump every time that one wrapped. Nothing runs at all in
the still mode — a hushed microphone repainted sixty times a second to draw the
same frame is a wake lock being spent on nothing.

**The two voices are the one place the scheme is left behind.** `heardColour`
and `spokenColour` in `ui/theme.dart` are flat indigo and teal rather than
`colorScheme.primary` and `tertiary`: a scheme's tones are picked to be read
*on* a surface, so the dark primary is nearly white and makes a pale smudge of
something meant to be lit, and an indigo seed resolves `tertiary` to a rose
that reads as a warning rather than as the other half of a conversation. The
hot middle of the orb moves *away* from the page — lighter in the dark, deeper
in the light — since a centre lightened on a white surface is a hole in the orb
rather than a light in it.

Three things about the drawing are worth knowing. The gradients — and the
paints holding them — are built once per colour and drawn as a **unit circle
under a canvas scale**, because a shader is a native allocation and a radius
that changes every frame would otherwise mean a shader every frame. A ring
travels from the orb *as it is now* to the edge of the box, so a swollen orb
does not push its own rings off the screen. And the box scales to the room the
column is given, since the same screen also holds a resume bar and a question
panel — by `AspectRatio` under a `ConstrainedBox` rather than by `LayoutBuilder`,
which would put every frame of the orb inside a **layout** pass: a build scope's
rebuild reaches its render object as `needsLayout`, and a `RepaintBoundary`
isolates paint, not layout.

**The page is split by what changes when.** `_Script` — the transcript, the
turn's surface and its questions — watches the chat, which moves sixty times a
second while a reply streams; the orb and the controls watch the session, which
moves a handful of times a turn. Watched together, every delta rebuilt the orb's
whole subtree and three `ButtonStyle`s with it. The bar's title is a third
watcher, on a `select` of its own.

A screen with the orb on it **never falls still**, so a widget test that pumps
one cannot `pumpAndSettle` — `pumpUntil` is what the tests reach for instead.

**Three buttons under it, one promise each**: Mute shuts the microphone, Stop
shuts the reply up and is dead unless there is one being read out, and Done
goes back to typing. They were the orb at first — which of the three a tap
meant depended on the status, so the same gesture stopped a reply, shut a
microphone or did nothing at all, and nothing on screen said the orb could be
tapped. So the orb now reports and nothing else. Stop is drawn in the reply's
own colour while it is live, since it is the one button that comes and goes
mid-turn. They sit bottom-most, where the composer is on the page this screen
stands in for.

Pausing is a *release* rather than a
stream left running and thrown away — the device stops recording, which is what
the system's own microphone indicator will say either way. It is a flag beside
the status rather than one of its values, because a turn can be running and its
reply being read out while the microphone is shut, and those are what the status
is for. Starting a session clears it: a fresh one listens whatever the last one
was doing. **It is the microphone and nothing else** — a reply being read out
goes on being read out, and the button that stops it is the one beside it. That
promise is kept below this as well as here; see "Mute is the microphone and
nothing else".

**The transcript is a five-line window that scrolls**, not five lines that roll
past and are gone: it is a viewport over every line said, so the start of the
conversation is still there to scroll back to. Two things follow. Five lines is
a *height* — five times the line height at the current text scale, held rather
than measured, because a viewport cannot lay its content out to discover how
tall it should be, which is the same answer `_TitleLine.height` gives the app
bar. And it follows the newest line through `ScrollFollow`, the gesture rule
`chat_page.dart` runs too — a line the reader has scrolled away from does not
pull them back, and what attaches again is arriving at the end.

**Its top fades out**, into the orb above it, so the line being read is the one
at the bottom. A mask over the viewport rather than an opacity per line: what
should be faint is whatever is at the top of the *view*, and a line dimmed by
its place in the list stays dim once it has been scrolled back to. It is also
the one thing on this screen that finding a widget cannot check — a blend mode
on its own passes with the gradient upside down — so the test paints it and
samples what came out.

What the user said is `onSurfaceVariant` and what was said back is `onSurface` —
the issue asks for grey and white, taken through the scheme so light mode works
too. **A tool run gets a line as well**, dimmer than either voice: a turn can
spend half a minute inside a sub-agent, and a screen that says nothing while it
does reads as a broken app rather than a working one.

The way in is a circle left of the composer's send button, drawn wherever the
platform can listen rather than only where models are installed — with none
picked it leads to the settings that pick them, which is a better answer than a
button nobody can find. `openVoice` is that rule, and `startVoiceChat` beside it
is the circle on the new-chat screen and the assistant gesture's voice view.
It **makes nothing**: the page opens on no chat and the first word is what
creates one, which is the rule the composer keeps and is written up under
"Taking turns". Both read `voiceReadyProvider`
themselves, which they can because **which models are installed is read before
the app is built** — `AppSession.start` scans for them and seeds
`InstalledVoiceModels` with what it found, the bargain `promptLibraryProvider`
already makes and for the reason it makes it. Asked lazily it is a disk scan
that answers "none" until it finishes, and a button's callback reads rather than
watches, so the first press would have offered settings to someone who has both
models however long the app had been open. That was first fixed by making it
the caller's problem — a `ready` parameter, and two comments saying it had to be
watched and not read — which is a contract every next way in has to be told
about, and is silently wrong when it is not. **It gives the field its width back the moment there is
a message in it**: something typed is something to send rather than to say. That
is an `AnimatedSize` around the button and nothing else — the row is laid out
again on every frame of it, and the `Expanded` field takes whatever it gives up.

## Touch to speak

Voice mode listens for as long as it is on screen, which is the point of it. The
setting in `VoiceSection` is the answer for a room where that does not work: the
microphone is open only while a Talk button is held. It is what a noisy room
leaves once the loudness gate has done what it can — a recogniser transcribes
whatever is loud enough, and past some amount of room the only reliable way to
say what was meant for the phone is to say when.

**Talk replaces Mute rather than standing beside it.** They are the same promise
about the microphone made the other way round, and two of them would leave a
muted session showing a Talk button that could not be answered. So it is
`VoiceViewState.pushToTalk` and not a fourth `_Key`, and `paused` carries the
same meaning it always did — the microphone is shut. What changes is the word
for it: a microphone waiting to be asked was never paused, so the orb says
`Ready` rather than `Paused`.

The button works on pointer down and up rather than on a long press: a gesture
that has to be recognised before it fires is a gesture the microphone opens late
for, and what is said in that half second is the half nobody hears. Pressing it
stops the reply: whoever holds a button down to speak is not waiting for the
rest of the answer. Releasing it keeps the sentence it was held for, which is
`setListening(false, finish: true)`.

The setting reaches a session that is already running, through a `ref.listen`
rather than a `ref.watch`: watching it rebuilds the notifier, and a rebuild
resets the state the session is being held in. A session started with it on
never opens the microphone at all, which falls out of the rule below rather than
being arranged: every session opens shut and `_holdMicrophone` is what asks.

Pressing it stops the reply without waiting for it to be quiet, and the press
does not wait either: stopping speech is a platform call of its own, and the
whole reason the button is on pointer-down is that the first half second is the
half nobody hears.

## Taking turns

**A session can exist before the chat does.** `voiceControllerProvider` is keyed
on `String?`, and null is a session started from the new-chat screen with
nothing to speak into; `VoiceController` makes the chat on the first word it
hears and speaks into it from there. That is the same rule the composer keeps —
a chat exists because something is in it — so a voice session nobody spoke in
leaves nothing behind, and there is no delete-if-empty anywhere to clean up
after one.

What it cost is that the session stopped being keyed on what it is about. The
key is how the page was opened; `_chatId` is what is being spoken into, seeded
from the key and moved once, by `_speakInto`, when a chat is made.

That move closes the old subscription before opening the new one, and the close
is load-bearing rather than tidy: `ref.listen` hands the element a subscription
to *dispose*, not to re-point, so one left open goes on reading the previous
chat's replies out into this session.

`VoiceViewState` carries `chatId`, because the page is built on the key and the
title and the transcript need the chat, which the key is not.

**The session is the page's, and that is what makes the null key safe.** The
provider is auto-disposed, so it lives exactly as long as something is watching
it — which is the page — and the next new voice chat builds a controller that
has never heard of the last one's chat. Nothing is put back anywhere, and there
is no window in which the old chat could be read: the alternative, resetting at
`start`, left the first frame of the next session showing the previous
conversation's title and five lines of its transcript, since `start` only runs
after it.

It is also what shuts the session. Leaving is the last watcher going, which
disposes the notifier, which runs `_shutdown` — so the page has no `dispose` of
its own. Stopping by hand there as well said the same thing twice and raced
with it. What that put on `_shutdown` is that it now runs on every page close
rather than only on a session that was started, which is why releasing the
foreground hold asks whether one was ever taken.

`stop` therefore leaves `_chatId` alone, and the screen goes on showing what was
said. The notification's Stop arrives with the page still up, and clearing the
chat there would take the transcript and the turn's own surface off it and leave
a blank screen with no way back. What `stop` does close is the *listening*: a
session that is off does not read replies out, and a subscription left open
fires on every flush of that chat for as long as the app runs.

**One voice session in the app, and it is written down rather than assumed.**
`runningVoiceProvider` holds whichever controller has the device, and `start`
takes it off that one before opening its own — the same thing it already did to
`ReadAloud`, which holds a speech model of its own. It holds the controller
rather than a key, because the key is how a page was opened and two pages can
share one.

That is not a hypothetical. The assistant gesture pushes a voice page over
whatever is on screen, a running session included, and the two are not
necessarily on the same key: over a chat it is `openVoice(X)`, and the gesture's
is null. Two keys are two controllers, and before this they were two
`VoiceSession`s — two microphones and two worker isolates, where
`lib/domain/voice.dart` says there is one of each. `BackgroundWork.listening` is
a flag rather than a count, so the first of them to end released the foreground
hold the other was still relying on. It predates deferring the chat; two keys
were reachable before that too.

`release` only clears its own claim, and only while there is something to
release to: a session is shut from `onDispose`, and on the way out of the app
that runs after the registry has gone itself. What it does not make impossible
is two pages *on screen* — the one underneath is left showing a session that
has stopped. That is a screen to go back from rather than a device held open.

**Handing over interrupts the turn the outgoing session had running.** Shutting
the microphone does not end a turn, and that is right where the page is still
up: `stop` from the notification leaves it running, because the reply is still
worth reading out and the user only asked for the microphone back. It is wrong
here. The page has been buried under the new one, its transcript is gone, and a
turn that parks on an approval or a question has nobody left to answer it — so
it ran on with the "running a turn" notification up and never ended, which is
exactly what was reported.

So `handOver` interrupts it, and the chat offers to carry it on rather than
recording it as something the user stopped — see "Carrying on an interrupted
turn" for what that means and how it is done. The session is shut *before* the
turn is, and that order is load-bearing: interrupting writes `isRunning: false`
into the chat, this session is listening to that until it is shut, and its
end-of-turn arm opens the microphone again — on the one path where another
session is trying to take it.

**One chat per session, however fast the words come.** The microphone is open
for as long as the chat is being written down, so a second utterance arrives to
find `_chatId` still null; `_creating` holds the one in flight so the second
waits for it rather than making a chat of its own for its words to be lost in.

And what was heard is said **even if the session stops while it is being
written**. Those words were spoken while it was on, and dropping them there
would leave the empty chat this whole path exists not to make.


**The microphone is open only when it is the user's turn to speak** — not while
a turn runs, not while the reply is read out. `VoiceController._wantsMicrophone`
is the whole of the rule and `_holdMicrophone` the only thing that acts on it,
running after every state write, so turn-taking is a consequence of the status
rather than something each transition has to remember. A session opens shut and
asking it for what it is already doing is a no-op, so nothing up here keeps its
own copy of whether the microphone is open.

It is worth writing down what this replaced. The microphone used to stay open,
and the phone hears its own voice as readily as it hears the person — one
acoustic event to a recogniser — so two mechanisms downstream existed to guess
which of the two it was: the words just spoken were kept in a buffer and matched
against what came back (`isEcho`), and onset was not trusted as an interruption
until a transcription confirmed it. Both were inference about a question that
did not need asking, and neither could be reliable. Not listening cannot be
wrong about it. `isEcho`, `Speaker.speaking` and `VoiceInterrupted` went with the
machinery they were written for.

**The loudness gate is not one of these and is still here.** It answers a
different question — whether what was heard was meant for the phone at all — and
a television two rooms away is that whether or not anybody is speaking. See
"What counts as being spoken to".

What this costs is talking over a reply to interrupt it, which is now Stop:
under the orb the whole time, instant, and not a transcription anyone has to
trust.

Two arms are worth knowing. A turn that says nothing out loud — one that only
ran a command, or was aborted — never reports silence, so the status is put back
to `listening` when the turn ends rather than when the speaking does; without it
the microphone never opens again. And a session opens *shut*, then
`_holdMicrophone` opens it like any other transition: opening a capture and
closing it again is a real start and stop of the device and the system's own
indicator flashing for nothing.
