# Voice mode

A circle for what the microphone hears and five scrolling lines of what has
been said, over a chat that was already open. Everything runs on the device,
and which device decides how: **the desktops run `sherpa_onnx`** — speech
recognition, speech synthesis and voice activity detection from one dependency,
with the models downloaded from the settings page rather than shipped — while
**Android runs the system's own engines** and has no models at all. See "The
Android system engines", which is also where the reasoning for that split is.

**A voice turn is an ordinary turn, and that is the constraint the rest is
written to keep.** `VoiceController` hands what it heard to
`ChatController.send` and reads the reply back out of the chat: same
`TurnSettings`, same model, same approve mode, same tools — `bash`, `task`,
`ask_user`, the lot — and the same records in `conv.jsonl`, so threads, resume
and rewind all work on a conversation that was spoken. Nothing in the backend
knows voice mode exists. Leaving it leaves a chat to read, and a chat being read
can be carried on out loud.

So `VoicePage` is a *view*, and its job is surfacing what a turn already does in
a shape you can use without looking. The approval banner, the question panel and
the sub-agent strip are **the same widgets** drawn here too, rather than reduced
voice-only versions: a turn waiting on an answer nobody can see is a hung turn,
and a second copy of either is a second thing to keep right.

The port is `Voice`, behind the app's one conditional import like `Shell` and
`WebSearch`. `Voice.available` is false in a browser, which is what leaves the
composer's circle undrawn — see issue #58 for why sherpa's WebAssembly is not
the answer there, and what is.

**It is kept out of the Android build too, and that one is measured in tens of
megabytes.** onnxruntime and sherpa's own library are about 26 MB per ABI,
uncompressed and page-aligned the way a modern APK stores native code: 75 MB
across the three, which took the universal release APK from 64.5 MB to 141 MB —
more than the rest of the app put together. With Android on the system engines
there is nothing left to load them, so they are excluded at packaging in
`android/app/build.gradle.kts` and the APK is back to 64.5 MB, measured.

**Excluded rather than removed, because they are not ours to remove.**
`sherpa_onnx` declares all ten of its per-platform packages in its own pubspec —
four Android ABIs, iOS, Linux, macOS, Windows, web — and pub resolves what a
package asks for. `dependency_overrides` is the only other lever and it replaces
a package on *every* platform, which is a risk worth taking once (below) and not
four more times. A `packaging { jniLibs { excludes } }` block drops the `.so`
files where they are actually unwanted and leaves every other platform's alone.
Vendoring the desktop libraries into `linux/CMakeLists.txt` instead would mean
dropping `package:sherpa_onnx` and writing the FFI bindings by hand — and
`sherpa_onnx_linux` already delivers those libraries through pub, so there is no
gap there to fill.

The one thing to know is that the exclusion and `platformVoice` have to agree:
the `.so` files are gone from Android, so a `SherpaVoice` constructed there
would fail at its first FFI call rather than degrade. `platformVoice` returns
`AndroidVoice` on that platform and nothing else builds one.

Keeping it off the web takes one deliberate piece of machinery.
**`sherpa_onnx` depends on `sherpa_onnx_web` whatever platform is being built**,
and that package declares a 14 MB WebAssembly build of onnxruntime as a
web-platform asset. Plugin assets are not tree-shaken, so simply adding the
dependency put 14 MB into a build that can never call it — measured: the web
build went from 43 MB to 58 MB. `tool/web/sherpa_onnx_web_stub` is a local package
of the same name, overridden in `dependency_overrides`, holding the two members
the web plugin registrant reaches for and no assets at all. Nothing on the web
imports `package:sherpa_onnx`, so none of the real API is ever wanted.

The trap in it is that a `dependency_overrides` entry replaces the package on
**every** platform, not only the one it was written for. If a `sherpa_onnx`
bump inside `^1.13.6` ever reaches a third member of `SherpaOnnxWeb`, the
desktop and Android builds break for a web-only reason — so the stub is
something to check when that constraint moves, which the espeak-ng note above
means it eventually will. The
Silero asset is kept out the ordinary way, with `platforms:` on its pubspec
entry.

## What listens and what speaks

`domain/voice_model.dart` is the catalog, as const data: five recognition models
and three speech ones, each naming its files, what it costs to fetch, and which
sherpa family runs it, and the two Android-system sentinels beside them. A model
Entoli can run is one someone wired an engine for, so a new entry is a line
there and a case in `sherpa_voice.dart`.

Recognition models are fetched **file by file** from HuggingFace — two to four
each — which skips the fp32 copies the release tarballs carry beside the int8
ones: the SenseVoice tarball is 999 MB for a 228 MB model. Speech models arrive
as the official `.tar.bz2` and are unpacked, because each carries
`espeak-ng-data`, some 360 files that are not worth fetching one at a time. bz2
in Dart runs at about 8 MB/s, so Kokoro spends a visible minute unpacking and
the progress bar has an "Unpacking" phase of its own; the work is in an isolate
so the bar can keep moving. `dart:io`'s native gzip would be twenty times
faster, and upstream publishes no `.tar.gz`.

**Kokoro is the only multilingual speech model there is at this size**, and it
is worth writing down why the list looks thin. Piper covers thirty languages one
model at a time, which is a language picker rather than a multilingual model;
MMS covers a thousand at rough quality and one model each; everything genuinely
multilingual beyond them is far too big for a phone. Whisper hears 99 languages
and Kokoro answers in two, and the honest fix for a third is one more const
entry.

Silero's detector is the exception that ships: 644 KB, an asset rather than a
catalog entry, because voice mode that cannot start until a second and invisible
download has finished is worse to explain than an app that is slightly bigger.
Every model sherpa takes it takes as a path, so it is copied out of the bundle
on first use. Its MIT licence is an asset too, read into `LicenseRegistry` the
way the font's OFL is.

**sherpa-onnx vendors espeak-ng, which is GPL-3.0.** Entoli is AGPL-3.0, so that
is fine — it would not be for a permissively licensed app, and it is the sort of
thing that is invisible until it is a problem. Upstream is removing espeak in
2.0, which will want lexicon-based models instead; the constraint is pinned at
`^1.13.6` until then.

## The Android system engines

A phone already has a speech recognizer and a speech synthesiser, and until this
landed voice mode ignored both and asked for a download first. So on Android
voice mode **is** the OS: `TextToSpeech` and `SpeechRecognizer` behind the
`agent_chat/voice` channel, with nothing to fetch — and sherpa-onnx is not built
into that platform at all.

**Why sherpa went rather than sitting beside them.** It ran on the CPU, and
there was no way to change that: the `libonnxruntime.so` in the pub package
exports exactly two execution-provider factories, `..._CPU` and `..._Nnapi`
(checked with `nm -D`), XNNPACK and QNN are named in its strings but have no
code in the build, and ONNX Runtime has no Vulkan, OpenCL or GPU provider for
Android at all. NNAPI is the only accelerator route and it is a bad one —
deprecated in Android 15, frequently *slower* than ORT's own kernels because
unsupported ops fall back to `nnapi-reference`, and it crashes outright on VITS
TTS (k2-fsa/sherpa-onnx#2443). So keeping it meant 75 MB of native code for the
slower of the two answers, on the one platform where battery is the constraint.

**What that costs is a phone with no system engine**, which is a real device
rather than a hypothetical: `SpeechRecognizer` needs a recognition service and
`TextToSpeech` needs an engine, and a de-Googled phone may have neither. Both
are ordinary apps that register with the platform, so the fix is an install
rather than a build — RHVoice or eSpeak NG for speaking, FUTO Voice Input for
hearing. `_MissingEngines` in `voice_settings.dart` is that said on the page,
with the links, because an empty picker on a platform with no catalog behind it
is otherwise a dead end that gives no sign of being one install away. Nothing
has to be told when one arrives: the next launch asks the device again.

The desktops keep sherpa, and there the reasoning does not apply — they have no
system engine to ask, and no battery argument of the same kind.

**They are catalog entries rather than a mode.** `android-recognition` and
`android-speech` are a `RecognitionModel` and a `SpeechModel` with no downloads,
in `voiceCatalog` but not in `recognitionModels`/`speechModels`. That is what
makes them cost nothing: every gate the app already has — `voiceReadyProvider`,
`speechReadyProvider`, the settings dropdowns, `ReadAloud`, `VoiceController` —
resolves a pick through `voiceModelOf` and asks whether it is installed, and a
sentinel answers both questions without any of them learning a new shape. A
`nativeVoice` flag beside the model id would have been a second thing every one
of those had to consult, and the one that forgot would be wrong silently.

`VoiceModel.isNative` is the whole of the routing, and it reads `engine` — the
field that already decides what runs a model, rather than a second id constant
beside it. `AndroidVoice.start` refuses anything else.
`Voice.downloadsModels` is the other half: false on Android, which is what takes
the catalog off the settings page, and it has exactly that one reader.

**What decides is whether the engine is there, not whether this is Android**,
and the answer goes into the set that already existed for the question.
`Voice.systemEngines()` asks the device — `SpeechRecognizer` needs a recognition
service installed and `TextToSpeech` needs an engine, and a phone with no Google
apps on it may have neither — and `main` folds what it says into
`installedVoiceModelsProvider` beside the models on disk. So a sentinel is
usable on exactly the terms a downloaded model is, and every gate is the
`installed.contains(...)` it already was: the ready providers, the settings
dropdown, the defaulting. "Is this Android" was the first version and it was
wrong on a real phone; a `nativeVoiceEnginesProvider` beside the installed set
was the second, and it was the thing this section's own rule warns about — a
second question each gate had to remember, silently wrong in the one that
forgot.

It is on `Voice` rather than in `core/platform/` because that port is already
per-platform and already built there, which keeps `io/platform.dart` resolving
`Platform.isAndroid` once instead of twice and leaves `platform.dart` with no
member exposed any way but its own. `FakeVoice` is then the test seam, so
`TestApp.create` takes `nativeVoice` and nothing parallel has to be overridden.

So **each side is defaulted on its own**. A phone with a synthesiser and no
recognition service gets the speaking half and leaves the listening half
unpicked, which is the honest answer: read-aloud works, the composer's voice
button stays away. A sentinel pinned by hand or carried in a `settings.json` is
refused by the same set, so it needs no rule of its own.

The default is filled in `AppSettingsNotifier.build` and **not written to
disk**. A file that names something is left as it is; only a null is read as
"the system one". Saved, it would be a pick the user never made, following their
data to a machine where it means nothing — and it would take the ability to say
"no pick yet" away from the platforms that have an answer for it.

The probe needs the manifest's `<queries>` block, and that is the trap in it:
from Android 11 an app sees only the packages it declares an interest in, and
both service queries are answered out of that view. Without it they report
nothing on every modern phone rather than only on the ones that genuinely have
nothing — which is a default that quietly stops working, in the direction that
looks like a device problem.

**The probe asks which service a session would connect to, rather than whether
one exists**, and the difference was a bug that looked like a device problem
too. `SpeechRecognizer.isRecognitionAvailable` is true when *any* installed
package declares a `RecognitionService`, while the one-argument
`createSpeechRecognizer` connects to the one named in
`Settings.Secure.VOICE_RECOGNITION_SERVICE` — and an unset setting is
`ERROR_CLIENT` the moment the session opens, which is voice mode saying
"Recognition failed (error 5)" before it has heard a word. A phone with a
recognizer installed and no assistant chosen is the ordinary way to be there.
So `recognitionServices` picks the components and both the probe and `listen`
go through it, and an empty list takes the sentinel off the settings page the
way a missing engine already does. There is no public API for the setting, so it
is read as a key — the constant itself is hidden.

**It answers with a list where there is no pick, and with the pick alone where
there is one.** A service cannot be asked anything before it is bound, and a
phone can carry one that holds no model at all with the one that would have
worked listed behind it — so where Android has been told nothing, a service that
never connects or that refuses every shape of the request below is fallen past
rather than reported, and only the last one's refusal reaches the user. Where
the user *has* chosen a recognizer, walking past it would hand the microphone to
another company's service, over the network, without saying so. That is not a
choice to make in a private Kotlin helper, so the walk is one service long and
the refusal is theirs to see.

`ERROR_CLIENT` is also what the framework's own `RecognitionService` answers a
`startListening` on a listener that is still in a session, so the same error
means two things: a restart posted from `onError` landing before the last
session was closed, and one that never connected. **What tells them apart is
whether a session ever opened**, which is what `onReadyForSpeech` says and what
`sessionOpened` holds — so the first is retried once, 200 ms out rather than on
the next turn of the looper, since a tear-down is what is being waited for, and
the second falls to the next service. A count with a threshold was the other
answer and it spends four failed binds arriving where the flag already is.

Reporting an error destroys the recognizer, and that is `fail` rather than a
line in each branch. Voice mode is in its failed state from that moment — the
Dart side has no way back short of leaving the screen — so a recognizer left
bound is a microphone held for a screen that has given up, and worse, one the
next unpause would drive on rather than resolve a service again. A phone that
had one installed while the app was open gets it that way.

### What is asked, and what to do when it is refused

`startListening` takes an intent, and the two things Entoli puts in that intent
are exactly the two a phone can refuse: `EXTRA_PREFER_OFFLINE`, and the language
it is to be heard in. A phone with no downloaded model for its own language
refuses both together as `ERROR_LANGUAGE_NOT_SUPPORTED` — **"Recognition failed
(error 12)", which is what voice mode said instead of hearing anything, on a
device whose recognizer would have worked perfectly well over the network.**
`ERROR_LANGUAGE_UNAVAILABLE` is the same thing said one step more precisely, and
means the same to us.

So the intent has three shapes and they are a ladder: on-device in the language
asked for, over the network in the language asked for, and over the network in
whatever language the service itself is set to. A language error is a step down
rather than a fault, and only a device that has refused every shape is told it
has no speech recognition for that language. **On-device stays the first rung**,
since the rest of voice mode is on the device, and being wrong about it now
costs one fast refusal instead of the whole feature.

**Asking first is the obvious alternative and is the slower one.**
`checkRecognitionSupport` will name the languages a bound service has
downloaded, so on Android 13 the rung could be picked rather than found — but it
is a bind and a round trip of its own, paid at the start of *every* session
including the ones that were about to work, to save a refusal that arrives in
tens of milliseconds and sticks for the rest of the session. It is worth it for
the one thing a refusal cannot do: **the fallback is not meant to be permanent,
so the model is asked for.** `triggerModelDownload` is called the first time a
service turns out to be missing a language it could hold, so the session that
fell back to the network is heard on the device the next time voice mode opens.
Once per service, since it is a fetch rather than a retry. The platform decides
whether to prompt and whether to wait for wifi, and nothing here waits for it or
hears how it went.

**The tag is stripped rather than taken.** A locale carries whatever `u-`
extension it was set with — a calendar, a numbering system — and a tag a service
cannot parse is a language it does not support, which is the same error 12
arriving for a reason that has nothing to do with what the device can hear. The
script stays on: for `sr-Latn` and `zh-Hant` it *is* the language.
`EXTRA_CALLING_PACKAGE` goes in beside it because nothing fills it in for a
`SpeechRecognizer` session, and a service that wants to know who is asking
answers a request without it as `ERROR_CLIENT`.


Everything the walk learned is dropped when the session ends. It was learned by
failing, and a phone that has since been given the language pack — or the
recognizer, or the assistant setting — would otherwise keep paying for what was
true when voice mode was last opened. Within a session it is kept, so pausing
for a reply and unpausing does not walk it again.

**A refusal does not always arrive dressed as a language error.** A rung that
cannot work at all — offline preferred where nothing is downloaded, say — is
answered by plenty of services with `ERROR_NO_MATCH` or `ERROR_SPEECH_TIMEOUT`
instead, which are silence's codes and would restart forever a few hundred
milliseconds in, voice mode listening and deaf. What separates that from a room
with nobody in it is speed: genuine silence takes the service's own timeout to
report, several seconds, while a refusal comes back almost instantly. Each
request is timestamped, and two near-instant silences in a row descend the same
ladder a language error does — `onBeginningOfSpeech` clears the count, so a
rung that hears never steps down for being quiet. The worst case of being wrong
is two fast cycles nobody noticed.

**The remaining codes are three kinds rather than a list.** Silence restarts and
says nothing — except as above, where it refuses fast enough to be asked again.
Something happening elsewhere — the network, the server, one request too many,
a service that went away under the session — is backed off and tried again,
three times before it is called a fault, since each of those is a blink at least
as often as it is a wall; `ERROR_RECOGNIZER_BUSY` is here rather than among the
silences, cancelled first, because restarting into a recognizer still holding
its last session was an immediate retry landing on the same error, forever.
Everything else reports: no microphone, no permission, and an error code nothing
here has a name for, which is still worth showing with its number rather than
swallowing.

### Which language it is asked in

`Locale.getDefault()` until the Settings page offered anything else, and still
the answer where it is left alone. A phone is set to one language and its owner
speaks the phone's language at it — until they do not, which is the ordinary
case for anyone bilingual, and there was no way to say so.

So `settings.json` carries a `voiceLanguage`, a BCP-47 tag or null for the
device's, and it reaches both halves: the recogniser's intent, and `setLanguage`
on the synthesiser. Dart carries it per strategy, since that is where a session
is composed, but **`VoiceChannel` keeps one field for both** — the two halves
are built separately and land in the same object, and a language each would be
two answers to a question the user was asked once. Null is not a special case
below that field either: `asked()` resolves it to the device's locale in one
place, and the recogniser and the synthesiser both read it from there.

**The list is the synthesiser's.** `getAvailableLanguages` is a plain getter on
a ready `TextToSpeech`, and every phone that can speak at all answers it. Naming
what the *recogniser* can hear is the harder half of the same question:
`checkRecognitionSupport` is Android 13 and up and needs a service bound, and
before that it is `ACTION_GET_LANGUAGE_DETAILS`, an ordered broadcast plenty of
services never answer. Asking the engine that will answer, and letting a tag the
recogniser dislikes descend the ladder above, is the cheaper shape of the same
outcome — and the ladder was already there for the device's own language.

A language is a **new session** rather than a live one. Changing it under a
running one would mean rebuilding the intent mid-utterance and setting a locale
on an engine with sentences queued behind it, for a setting nobody changes while
talking; the field is written by whichever half of the next session starts
first, and read from then on.

**A pick either engine cannot do is said out loud.** The recogniser's refusal
already walks the ladder and, at the end of it, names the language on screen.
The synthesiser's does not refuse at all — `setLanguage` returns a code, and
ignoring it leaves the engine speaking whatever it was speaking before, which is
an answer read out in the wrong language with nothing anywhere to explain it. So
the code is checked, the device's own is put back, and the fallback is a `Log.w`
in a release build like any other arm nothing draws.

### Ending the utterance

**A session that never ends is a turn that is never sent**, and on a phone in a
room with anything happening in it that is the ordinary way for voice mode to
fail. `SpeechRecognizer` decides for itself when someone has stopped talking,
and its own detector is generous: a fan, a television, a conversation elsewhere
all read as speech continuing, so `onResults` never arrives and nothing is ever
handed to a turn. From Dart it is indistinguishable from a microphone that is
not working — voice mode sits there listening and apparently deaf.

The intent asks for a silence length, and that is a hint every one of those
extras is documented to be. What actually ends it is in `VoiceChannel.kt`:
**what says the person has stopped is the transcription, not the sound.**
Partial results stop changing while the room goes on making noise, so a partial
that has not moved for `QUIET_MS` — or `MAX_UTTERANCE_MS` of anything at all —
is answered with `stopListening`, which is the same call the Talk button's
release makes and asks the service for what it has.

**One timer and one call, and it is worth knowing what a second and a third
cost.** The first version also capped the utterance's length and escalated to
cancelling the session where `stopListening` went unanswered — three mechanisms
interleaved with the restart machine, which already has timers of its own. The
cap's arithmetic ran against a clock field that was still zero, so the timer
fired immediately, `stopListening` landed on a session that had not opened, and
the escalation raced the restart that the resulting error was already
scheduling. Two `startListening` calls in flight is `ERROR_CLIENT` before a
session opens, which walks the service list and reports "Speech recognition
could not start." — on a phone whose recogniser works fine.

So a service that ignores `stopListening` is left exactly where it was before
any of this, which is the honest fallback, and `restart` now keeps at most one
pending relisten so nothing else can stack them either.

### What counts as being spoken to

**Both engines are generous about what counts as speech**, in their own ways: a
system recogniser transcribes a television two rooms away, and Silero calls
plenty of it voice. Every one of those was a turn. So an utterance is judged
after the fact by `LoudnessGate` in `domain/loudness.dart` — fed by
`MicrophoneListener` from whatever its engine reports, and asked at each result.

**There is not a single absolute number in it, and the first version's bug is
why.** It compared the utterance against the room plus a fixed margin, in the
units `onRmsChanged` reports — whose documented -2..10 is a typical range and
not a contract. On a device reporting a narrower one the margin was unreachable,
so nothing was ever loud enough and voice mode answered nobody. A gate that can
be wrong that way is worse than no gate: it fails silently, and it looks exactly
like a broken microphone.

So the bar is a share of how loud this person turns out to be, measured rather
than assumed. Nothing is refused until a voice has been heard to compare
against, so the first utterance always carries whatever it was; that utterance
sets the level and the bar is a fraction of it. A level set by the wrong thing
corrects itself upward, since a real voice is louder than the television that
set it, and downward, since the level decays at every judgement — one shout is
not the bar for the rest of the session.

What is left of the room is the **floor** the utterance is measured above, and
that is a minimum rather than an average: a floor that follows what it hears
climbs into a long sentence and reports that nobody said anything. It is the
quietest reading of the last two blocks, so it takes a genuinely quieter room to
move it and no amount of talking will. That is also why nothing tells the gate
where speech began any more — it does not need protecting from it.

The same measurement is what `level` follows, against the loudest anything has
been rather than against a scale, so the orb moves the same amount in a quiet
room and a noisy one.

### One listener, two engines

`MicrophoneListener` is what a `Listener` with a microphone behind it is made
of, which turned out to be everything except the engine: the event stream, the
level, and the gate. It exists because the gate did not — it was written for the
system recogniser and lived in that class, so the desktops answered the
television for as long as Android had stopped. An engine now gets it by being a
listener rather than by remembering to be one, and what a subclass supplies is
only what its engine gives it: readings through `measured`, onset through
`began`, words through `heard`. The sherpa half measures one reading per
detector window — 32 ms of audio whatever size the platform's chunks are — on
the `decibels` scale; the Android half passes `onRmsChanged` through. Since
neither number is compared against anything absolute, one gate serves both.

`SpeechFailures` is the same story on the speaking side: one sentence lost is
not a broken engine and three in a row is, which was the system synthesiser's
rule and only its own — so on the desktops one sentence a voice would not say,
or one wav the player refused, ended voice mode. The sherpa worker also answers
every sentence now, including the ones it generates no samples for: a sentence
that came back as nothing left the count standing, so the queue never drained,
silence was never reported — and with it the status that puts the microphone
back. A reply that said nothing would have ended the conversation.

### Mute is the user, not the conversation

**Mute mutes the person, the way it does on a call.** The reply being read out
goes on being read out, the next turn still runs, and — the part that is easy to
get wrong — what was already being said into the microphone is handed over
rather than dropped. Somebody who speaks and then mutes is saying they have
finished talking and is waiting for an answer; a mute that threw that sentence
away left the turn unsaid and voice mode looking broken.

That is `setListening(false, finish: true)`, the same call letting go of the
Talk button makes: `stopListening` rather than `cancel`, so the service delivers
what it has. Sherpa honours it too — the detector is holding a segment that no
further audio is coming to end, so the worker is told to flush it.

**Everything else a shut microphone flushes is dropped**, and that rule is
`ComposedVoiceSession`'s. Neither engine stops on the instant it is asked to: a
cancelled `SpeechRecognizer` session hands back what it had, and audio already
given to sherpa's worker decodes after the recorder is released. Forwarded, that
is words nobody spoke into a microphone that is off, landing in the middle of
somebody else's turn. The session owns `setListening` and owns the event stream,
so it is the one place that knows both — and the flags are set before the call
goes down, since what the engine does with the request takes a platform hop and
what it flushes in between is exactly what this drops. Written in each
`Listener` instead it was two copies, and the second one was not written: the
sherpa path forwarded what its worker decoded after the recorder had gone. A
failure is not covered by it, since it is why the microphone is doing nothing.

Kotlin still guards `onRmsChanged` on `wantListening`, and that is about traffic
rather than about the rule: it is a codec encode and a main-thread hop many
times a second, and the microphone is shut for most of a conversation.

### Per side, not per session

`SherpaVoice` used to be one class holding a microphone, two workers and a play
queue, and a native engine could not be half of that. So listening and speaking
are `Listener` and `Speaker` in `voice_strategies.dart`, and
`ComposedVoiceSession` holds one of each and wires them together. Neither half
knows which the other is.

The split was built to let the two kinds mix per side, which no platform now
does — Android is native on both and the desktops are sherpa on both. It earns
its keep anyway, twice: `AndroidVoice` is a dozen lines because the session, the
shut-microphone rule and the silence reporting were already somewhere neither
engine owned, and `read_aloud` gets a speak-only session by passing a null
`Listener` rather than by either engine knowing what reading one message out is.

### The Kotlin

`VoiceChannel.kt`, registered on the cached engine against the application
context like the other three — the engine outlives the activity. Three things
about it are not obvious:

**`SpeechRecognizer` hears one utterance and stops.** Continuous listening is a
`wantListening` flag and a restart from `onResults`/`onError`, posted rather
than called where it happens: the old recognition is still running inside the
callback, and starting the next one there is what `ERROR_RECOGNIZER_BUSY` is.

**Silence is not a fault.** A room with nobody talking in it produces
`ERROR_NO_MATCH` or `ERROR_SPEECH_TIMEOUT` every few seconds, so those restart
without a word — unless they come back near-instantly twice running, which the
refusal section above covers. `ERROR_INSUFFICIENT_PERMISSIONS` is the one that
stops.

**The synthesiser answers only once it is up.** `TextToSpeech` is constructed
long before its init callback runs, and a `speak` in that window returns an
error code and no callback — Dart would count an utterance that never happened,
and a `_pending` that never drains is a queue that never reports itself silent,
which is the status stuck on `speaking` and a microphone that never reopens.
So Kotlin says `speechReady` when init succeeds, and Dart holds what it is
handed until then; an engine that has not answered within five seconds is said
rather than waited for. One utterance failing is likewise not the engine
failing: `speechUtteranceError` drops just that sentence, and three in a row
with nothing heard between them are what fail the session.

**`TextToSpeech` answers on a binder thread**, and a `MethodChannel` may only be
touched from the main one. Everything Dart hears goes through `send`, which
posts. Invoked where it happened it would be a crash in the one path nothing on
a desktop exercises.

`AndroidVoiceBridge` is the Dart mirror of the same constraint from the other
end: `setMethodCallHandler` takes one handler and two strategies each setting
one would leave the second overwriting the first, so the bridge owns the handler
and the strategies register callbacks on it.

No new permissions — `RECORD_AUDIO` was already declared and the synthesiser and
recognizer need none. The **grant** is a different matter: `SpeechRecognizer`
reports the lack of one as an error rather than asking, and nothing else on the
native path would ask at all. `SherpaVoice.start` asks for both kinds of
listener through `AudioRecorder.hasPermission`, which is the only thing in the
app that can, and the native branch throws the recorder away again.

`VoiceService` is untouched. The microphone still needs holding for as long as
voice mode is listening; only the engine behind it changed.

## Where the models live

`<cacheDir>/models/{stt,tts}/<id>/`, and **outside the data directory** for a
reason bigger than tidiness: `backup.dart` zips that directory whole, so a
Kokoro and a Whisper base in it would put three hundred megabytes of
bytes-you-can-fetch-again into every export — and a restore, which *replaces*
the data directory, would drag them between machines and wipe whatever was
already downloaded. Outside it, both are true by construction rather than by a
rule in `writeBackup` that someone has to remember.

A downloaded Linux is beside them, at `<cacheDir>/rootfs/<id>/`, and it is there
for exactly the same two reasons — see "A whole Linux under proot".

`platformCacheDir` resolves it by hand, the way `platformDataDir` does:
`$XDG_CACHE_HOME/agent-chat` or `~/.cache/agent-chat` on Linux,
`~/Library/Caches/agent-chat` on macOS, `%LOCALAPPDATA%\agent-chat\Cache` on
Windows, and `$AGENT_CHAT_CACHE` over any of them.

**Android is the one place "cache" is the wrong word.** `getCacheDir()` is
evictable — the system empties it under storage pressure and the app's settings
offer a Clear Cache button that does the same — and a 140 MB model the user
deliberately downloaded must not go that way. `FilesChannel` already stages
shares in `cacheDir`, where losing a copy is harmless; this is not that. So
Android uses the support directory, a sibling of the `app_flutter` tree the data
directory lives under: outside the backup, and not thrown away.

A `.complete` marker is written last in each model's directory, and it is the
whole of what "installed" means — the same trick `turnEnd` plays in
`conv.jsonl`. `installed()` reads the directories rather than the catalog, so a
model the catalog has since renamed still shows as taking up the space it takes
up. Cancelling a download cancels the subscription, and the store deletes the
half-written directory when its listener goes.

## Hearing and speaking

`SherpaVoice.start` loads the two models and takes the microphone's grant; what
comes back is a `VoiceSession` with the microphone still shut, and where **two
worker isolates** live. sherpa's
calls block, so on the UI isolate a Whisper encode is a frozen screen. They are
two rather than one because generating a spoken sentence takes about a second,
and a single worker would have the microphone's frames queued behind it — which
is exactly when the user is most likely to talk over the reply, and exactly the
moment the detector would be deaf.

Audio in is `record` at 16 kHz mono PCM, chunked to Silero's 512-sample window
before it is handed over. `Pcm16Reader` is what does the chunking, and it is a
class of its own because both things it gets right are invisible: a chunk is a
*view* into the buffer the platform channel decoded into, starting at byte 5 of
it on Android, and `asInt16List` refuses an odd offset outright — every frame of
every session threw, so voice mode listened to nothing at all. The other is that
a chunk does not have to end on a sample, and a byte dropped there shifts every
sample after it. Audio out is `audioplayers` over a WAV written per
sentence, into the system's temporary directory rather than the model one —
which on Android is deliberately the directory that is *not* evicted, and is
the wrong home for a file that lives for one sentence. `flutter_pcm_sound`
would be lower latency and has no Linux or Windows. **On Linux the microphone is `parecord`**, which `record` shells out
to — `pulseaudio-utils`, which a PipeWire system has as well — so a machine
without it gets a voice session that fails to start rather than one that hears
nothing.

**Only text parts are spoken**, and sentence by sentence as they stream, so the
first sentence is being read while the rest of the reply is still being written.
`speakable` is what makes a reply worth hearing: markdown is written to be
looked at, so a heading read verbatim is a run of hashes and a bold word is a
word between asterisks. **Fenced code is dropped whole** rather than flattened —
a command read out character by character is unusable to listen to and unusable
to type from, and the conversation is still on screen for anyone who wants it.
`SentenceSplitter` is fed the whole reply each time rather than the delta, which
is what the controller has; it refuses to split on `3.14`, `main.dart` and
`e.g.`, and breaks a run-on paragraph at a comma rather than hold up the first
sound the user hears.

`SpeakableText` is the same bargain a second time: fed the whole reply, keeping
what it has already worked out. Stripping is eight passes over each line, the
transcript is redrawn on every flush of a turn, and the speech path looks four
times a second, so re-stripping the whole reply each time costs more the longer
it gets — the same growth the splitter is fed the whole text to avoid paying
twice. What makes it possible is that a reply only ever grows, so every line
before the last break is settled; only the line still being written is stripped
again, and its fence is not counted, since an opening fence is not open until
the line it is on ends. Both readers of a streaming reply use it, and it is
`speakable` that they still agree with.

**Settled lines are kept joined, not kept in a list**, and the `\n{3,}` collapse
is done as they arrive — a run of three newlines is two blank lines in a row,
which is a thing to notice on arrival rather than to scan the whole reply for
afterwards. Without both, a look still cost a join of every line and a regex
pass over all of it, which is the same growth one step quieter. The same reply
asked for twice is answered from the last answer, since a turn changes far more
than its text and the transcript is redrawn for all of it.

**The line still being written is trimmed rather than stripped where no rule
can reach it**, which is what settling cannot do anything about: nothing settles
until a line break arrives, so a reply written as one unbroken paragraph was
stripped whole on every look. The eleven patterns are two kinds. Six are
anchored to the start of a line — the fence, the rule, the bullet, the quote,
the heading, the table's own row, and the pipe handling with them — so they read
only how the line *starts*, which is fixed as soon as it has a character that is
not a space. The other five need one of ``* _ ~ ` [ <`` or `|` to fire at all.
A line with neither is one all eight passes are about to hand back unchanged,
so it is handed back unchanged. The markup is looked for once per character
rather than once per look, since it only ever arrives: a line that has any has
it for good, and falls back to being stripped for the rest of its length, which
is where every line was before this.

Measured over three hundred looks, microseconds per look, incremental against
whole: one paragraph, 6 against 234 at 4,000 characters, 24 against 928 at
16,000, 92 against 3,694 at 64,000; line-broken, 4 against 244, 10 against 973,
52 against 3,855. What is left growing is the copy of the answer, which is
what the answer is.

**Settling inside a line is the other answer and is not worth its price.** A
split point has to be outside every construct, and a sentence end is not one:
`. ` falls inside `[Fig. 3](x)` and `*One. Two*` as readily as a space does, and
the anchored rules re-fire on the tail, so `Words here. - not a bullet.` loses
its dash. Of thirteen splits at a `. `, eight change what is said. Making it
sound means a second, hand-written account of what those five patterns match,
kept in agreement with them forever — where the guard above is a set of seven
characters, and is wrong only in the direction of doing the work anyway.

It is tested against `speakable` at *every* length a reply passes through, which
is the only assertion that means anything about a thing whose whole job is to
agree with something else — and that is what carries the collapse being moved
out of the regex, since every run length has to agree at every prefix.

A sentence is generated ahead of being heard, so **the queue running dry is not
the end** — the session only says it has fallen silent once nothing is still in
the worker. Without that count a fast model reports silence between every two
sentences, which in voice mode flickers the circle and in a message being read
out would stop it after the first sentence. The WAV of what is playing is kept
until something else is: `play` returns when playback *starts*.

**Nothing here has to tell the reply from the room**, because the microphone is
shut while one is being read out — see "Taking turns" for what that replaced and
what it costs. Stop, under the orb, is how a reply is cut off.
