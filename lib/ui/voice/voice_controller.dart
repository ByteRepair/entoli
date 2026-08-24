import "dart:async";


import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/background_work.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../domain/speech_text.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "../../providers.dart";
import "../chat/chat_controller.dart";
import "../sidebar/sidebar.dart";
import "../theme.dart";
import "read_aloud.dart";

/// What voice mode is doing, which is what the orb draws.
enum VoiceStatus {
  /// Not in voice mode. The state a controller is built in and returns to.
  off,

  /// Loading the models and opening the microphone.
  starting,
  listening,

  /// A turn is running and nothing has been said back yet.
  thinking,
  speaking,

  /// Something went wrong that voice mode cannot carry on past. [VoiceViewState.error]
  /// says what.
  failed,
}

class VoiceViewState {
  const VoiceViewState({
    this.status = VoiceStatus.off,
    this.error,
    this.level,
    this.paused = false,
    this.pushToTalk = false,
    this.chatId,
  });

  final VoiceStatus status;
  final String? error;

  /// The chat this session is speaking into, or null before the first word has
  /// made one. What the title and the transcript are drawn from, since a
  /// session started from the new-chat screen has no chat to be keyed on.
  final String? chatId;

  /// The microphone is shut. Not one of the [status] values: a turn can be
  /// running and its reply being read out while the microphone is off, and
  /// those are what the status is for.
  final bool paused;

  /// The microphone is only open while the Talk button is held, which is the
  /// setting rather than anything the session decided. Here because it changes
  /// what [paused] *means* — a shut microphone waiting to be asked rather than
  /// one the user muted — and the controls and the word under the orb both
  /// have to say the right one.
  final bool pushToTalk;

  /// How loud the microphone is. Held here rather than folded into [status] so
  /// the orb can follow it without the transcript rebuilding for every audio
  /// frame.
  final ValueListenable<double>? level;

  bool get isOn => status != VoiceStatus.off && status != VoiceStatus.failed;

  /// The microphone is shut and nothing is being said, which is the one look
  /// that is about the state rather than the status.
  bool get hushed => paused && status != VoiceStatus.speaking;

  /// What the screen says this is. The two words for a shut microphone are the
  /// state's rather than the status's, which is why it is not all on the enum —
  /// and they are two because a microphone waiting to be asked was never
  /// paused.
  String get word => hushed ? (pushToTalk ? "Ready" : "Paused") : status.word;
}

extension VoiceStatusWord on VoiceStatus {
  String get word => switch (this) {
        VoiceStatus.off => "Off",
        VoiceStatus.starting => "Starting",
        VoiceStatus.listening => "Listening",
        VoiceStatus.thinking => "Thinking",
        VoiceStatus.speaking => "Speaking",
        VoiceStatus.failed => "Failed",
      };
}

/// What voice mode is drawn in, asked once by everything that draws it: the
/// orb, the dot beside the word, and the button that stops a reply.
Color voiceColour(VoiceViewState state, ThemeData theme) =>
    switch (state.status) {
      VoiceStatus.failed => theme.colorScheme.error,
      // Paused reads as off rather than as a state of listening, since that is
      // what it is: the device has stopped recording.
      _ when state.hushed => theme.colorScheme.onSurfaceVariant,
      VoiceStatus.speaking => spokenColour(theme.brightness),
      _ => heardColour(theme.brightness),
    };

/// Voice mode over one chat. **It has no conversation of its own**: it hands
/// what it heard to [ChatController.send] and reads the reply back out of the
/// chat, so a spoken turn is an ordinary turn — same model, same tools, same
/// records in `conv.jsonl` — and leaving voice mode leaves a chat to read.
class VoiceController extends Notifier<VoiceViewState> {
  VoiceController(this.openChatId);

  /// The chat this session was opened over, or null for one started from the
  /// new-chat screen — which has no chat until it hears something.
  final String? openChatId;

  /// The chat being spoken into. [openChatId] until the first word makes one.
  String? _chatId;

  /// The settings that chat will be made with, handed over by [start] from the
  /// screen that offered them before there was anything to write them on.
  ChatMeta? _meta;

  /// Only [_speakInto] and [_shutdown] touch it: there is nothing to listen to
  /// until there is a chat, and nothing to listen for once the session is off.
  ProviderSubscription<ChatViewState>? _chatEvents;

  /// The chat being made, while it is being made — see [_startChat].
  Future<String?>? _creating;

  VoiceSession? _session;
  StreamSubscription<VoiceEvent>? _events;
  StreamSubscription<BackgroundJob>? _stops;

  final _sentences = SentenceSplitter();

  /// The same reply, stripped. [SpeakableText] rather than [speakable]: this
  /// runs over the whole reply so far, four times a second, for as long as one
  /// streams. It answers what `speakable` answers at every length a reply
  /// passes through, which is what its own test asserts.
  final _speakable = SpeakableText();

  /// Held rather than read when it is needed: [_shutdown] runs from
  /// `ref.onDispose`, where the ref is already gone.
  late BackgroundWork _work;

  /// The reply being read out, so a new one starts the splitter over rather
  /// than carrying on from where the last one stopped, and the parts it was
  /// last read from — a chat state change that touched no text has nothing new
  /// to say, and most of them do not.
  String? _reading;
  List<MessagePart>? _read;

  /// A turn flushes about sixty times a second, and each pass re-strips the
  /// whole reply so far — which grows, so the cost over a turn is quadratic.
  /// Speech is spoken at human pace and a sentence is only said once it is
  /// whole, so reading it four times a second is inaudibly different and a
  /// fifteenth of the work. One-shot and re-armed, never periodic: a timer
  /// that rearms itself forever is a widget test that never settles.
  Timer? _due;
  static const _readEvery = Duration(milliseconds: 250);

  @override
  VoiceViewState build() {
    _work = ref.watch(backgroundWorkProvider);
    // Read rather than watched, and listened to for changes: watching it would
    // rebuild this notifier, and a rebuild resets the state a running session
    // is being held in.
    ref.listen(appSettingsProvider.select((s) => s.voicePushToTalk),
        (_, on) => unawaited(_setPushToTalk(on)));
    _listenToChat();
    ref.onDispose(() => unawaited(_shutdown()));
    return VoiceViewState(
        chatId: _chatId,
        pushToTalk: ref.read(appSettingsProvider).voicePushToTalk);
  }

  /// Listen to whatever this session is speaking into — the chat it made, or
  /// the one it was opened over. Both [build] and [start] want that and not a
  /// reset: a rebuild must not lose a chat made since, and a session restarted
  /// on the same page is still that page's session.
  void _listenToChat() => _speakInto(_chatId ?? openChatId);

  /// Point the session at a chat, or at none — the only thing that moves
  /// `_chatId`, and it closes before it re-opens. Publishing is the caller's:
  /// [build] has no state to write yet. See "Taking turns".
  void _speakInto(String? id) {
    _chatEvents?.close();
    _chatEvents = null;
    _chatId = id;
    if (id != null) {
      _chatEvents = ref.listen(chatControllerProvider(id), _onChat);
    }
  }

  ChatController get _chat => ref.read(chatControllerProvider(_chatId!).notifier);

  /// Every state write goes through here. Written out at each call site, the
  /// two `failed` arms silently omitted the level, which is the sort of
  /// difference nobody sees until the circle stops moving.
  void _show(VoiceStatus status,
      {String? error, bool? paused, bool? pushToTalk}) {
    final was = state.status;
    state = VoiceViewState(
      status: status,
      error: error,
      level: _session?.level,
      paused: paused ?? state.paused,
      pushToTalk: pushToTalk ?? state.pushToTalk,
      chatId: _chatId,
    );
    if (state.status != was) {
      voiceLog(() => "${was.name} -> ${state.status.name}");
    }
    _holdMicrophone();
  }

  /// Whether the microphone should be open right now.
  ///
  /// **It is open only when it is the user's turn to speak** — not while a turn
  /// runs, not while the reply is read out. That is what makes this a
  /// conversation rather than a room with a microphone in it.
  ///
  /// It answers one question and answers it exactly: *is the phone hearing
  /// itself?* Matching the reply's own words back against what came in, and
  /// waiting for a transcription before believing an interruption, were both
  /// inference about that — and neither could be reliable, because the reply
  /// and the room are one acoustic event to a recogniser. Not listening cannot
  /// be wrong about it. The loudness gate is not one of these and stays: it
  /// answers a different question, whether what was heard was meant for the
  /// phone at all, and a television is that whether or not anyone is speaking.
  ///
  /// The cost is that talking over a reply no longer stops it. Stop does, and
  /// it is under the orb the whole time.
  bool get _wantsMicrophone {
    if (!state.isOn || state.paused) return false;
    // Touch to speak: the button is the whole of it, and the turn it belongs to
    // is whichever one the user pressed it during.
    if (state.pushToTalk) return true;
    return state.status == VoiceStatus.listening;
  }

  /// Called after every state write, so the turn-taking above is a consequence
  /// of the status rather than something each transition has to remember. The
  /// session drops the call where nothing changed.
  ///
  /// A close while [VoiceViewState.paused] is the user saying they have
  /// finished talking — mute, or letting the Talk button go — and the sentence
  /// in flight is the point of it. A close because the turn moved on is not,
  /// and there is no third kind.
  void _holdMicrophone() => unawaited(
      _session?.setListening(_wantsMicrophone, finish: state.paused));

  Future<void> start({ChatMeta? meta}) async {
    if (state.isOn) return;
    _meta = meta;
    // Re-opens the listening [_shutdown] closed. Nothing is reset here: the
    // session is the page's, so a new one is a new notifier — see "Taking
    // turns".
    _listenToChat();
    final settings = ref.read(appSettingsProvider);
    final recognition =
        voiceModelOf<RecognitionModel>(settings.voiceRecognitionModelId);
    final speech = voiceModelOf<SpeechModel>(settings.voiceSpeechModelId);
    if (recognition == null || speech == null) {
      voiceFailed("no models picked");
      return _show(VoiceStatus.failed,
          error: "Pick a recognition model and a speech model in Settings first.");
    }

    // One session at a time. `ReadAloud` holds a speech model of its own, and
    // a message still being read out would be a second copy of it and a second
    // voice over this one.
    await ref.read(readAloudProvider.notifier).stop();
    if (!ref.mounted) return;

    final pushToTalk = settings.voicePushToTalk;
    _show(VoiceStatus.starting, paused: pushToTalk, pushToTalk: pushToTalk);
    try {
      // A session opens shut, and [_holdMicrophone] lets it open on the
      // `listening` below like any other transition.
      final session = await ref.read(voiceProvider).start(
            recognition: recognition,
            speech: speech,
            speaker: settings.voiceSpeaker,
            language: settings.voiceLanguage,
          );
      // Stopped while the models loaded. `ref.mounted` does not catch it — the
      // notifier outlives the screen — and without this the microphone opens
      // with nothing on screen.
      if (!ref.mounted || state.status != VoiceStatus.starting) {
        return unawaited(session.dispose());
      }
      _session = session;
      _events = session.events.listen(_onVoice);
      // Its own kind: the notification's Stop leaves voice mode and leaves a
      // running turn alone, which has a Stop of its own.
      _stops = _work.stopRequests
          .where((job) => job == BackgroundJob.voice)
          .listen((_) => unawaited(stop()));
      unawaited(_work.listening(true));
      _show(VoiceStatus.listening);
    } catch (e) {
      voiceFailed("session did not start: $e");
      _show(VoiceStatus.failed, error: "$e");
    }
  }

  Future<void> stop() async {
    // Mounted first: reading `state` on a disposed notifier throws, and the
    // page's `dispose` reaches this after a container has gone — where
    // `onDispose` has already done the shutting down.
    if (!ref.mounted || state.status == VoiceStatus.off) return;
    await _shutdown();
    // The chat is left where it is, so the screen still shows what was said —
    // the notification's Stop reaches this with the page still up.
    if (ref.mounted) _show(VoiceStatus.off);
  }

  /// Mute, in `VoiceControls`.
  Future<void> togglePaused() => setPaused(!state.paused);

  /// The Talk button, pressed and released. Pressing it stops the reply, since
  /// somebody holding a button down to speak is not waiting for the rest of the
  /// answer.
  Future<void> talk(bool on) async {
    if (!ref.mounted || !state.isOn) return;
    // The reply's silence is not waited for: stopping speech is a platform call
    // of its own, and the whole reason this is on pointer-down is that the
    // first half second is the half nobody hears.
    if (on && state.status == VoiceStatus.speaking) unawaited(hush());
    await setPaused(!on);
  }

  /// Mute the microphone, or open it again.
  ///
  /// **It mutes the user, not the conversation** — which is what mute means on
  /// a call. The reply being read out goes on being read out, the next turn
  /// still runs, and what was already being said into the microphone is handed
  /// over rather than dropped: someone who speaks and then mutes is saying they
  /// have finished talking, and expects an answer.
  Future<void> setPaused(bool paused) async {
    if (!ref.mounted || !state.isOn || paused == state.paused) return;
    _show(state.status, paused: paused);
  }

  /// The setting changed under a session. Turning it on shuts the microphone
  /// until it is asked for; turning it off opens it, which is what voice mode
  /// without a button is.
  Future<void> _setPushToTalk(bool on) async {
    if (!ref.mounted || !state.isOn) return;
    // Both at once: the setting and the microphone it decides move together,
    // and two writes would rebuild the screen twice for one toggle.
    _show(state.status, paused: on, pushToTalk: on);
  }

  /// Shut the reply up without leaving voice mode — Stop, in `VoiceControls`,
  /// and the way to interrupt an answer now that talking over one cannot be:
  /// the microphone is shut while it is being read out.
  Future<void> hush() async {
    if (!ref.mounted) return;
    await _session?.stopSpeaking();
    _sentences.reset();
    if (ref.mounted && state.status == VoiceStatus.speaking) {
      _show(VoiceStatus.listening);
    }
  }

  Future<void> _shutdown() async {
    _due?.cancel();
    _due = null;
    // A session that is off does not read replies out, so it has no business
    // still listening for them: left open this fires on every flush of that
    // chat for as long as the app runs, to decide it is off each time.
    _chatEvents?.close();
    _chatEvents = null;
    final session = _session;
    _session = null;
    await _events?.cancel();
    await _stops?.cancel();
    _events = null;
    _stops = null;
    await session?.dispose();
    unawaited(_work.listening(false));
  }

  void _onVoice(VoiceEvent event) {
    if (!state.isOn) return;
    switch (event) {
      case VoiceHeard(:final text):
        unawaited(_say(text));
      case VoiceFellSilent():
        if (state.status == VoiceStatus.speaking) _show(VoiceStatus.listening);
      case VoiceFailed(:final message):
        _show(VoiceStatus.failed, error: message);
    }
  }

  Future<void> _say(String text) async {
    if (text.trim().isEmpty || !state.isOn) return;
    if (_chatId == null && !await _startChat()) return;
    // A turn still running here is one whose utterance arrived late — the
    // microphone is shut for as long as one runs. Aborting waits for the turn
    // to be written and closed, so what is said next lands after it rather than
    // into it.
    if (ref.read(chatControllerProvider(_chatId!)).isRunning) await _chat.abort();
    if (!ref.mounted) return;
    // Sent whether or not the session is still on — these words were heard
    // while it was. The status is not: a stopped session is not thinking.
    if (state.isOn) _show(VoiceStatus.thinking);
    await _chat.send(text);
  }

  /// The first word of a session started with nothing to speak into, and one
  /// at a time — a second utterance arrives while this is still writing. See
  /// "Taking turns".
  Future<bool> _startChat() async {
    final id = await (_creating ??=
        ref.read(selectedChatIdProvider.notifier).create(meta: _meta));
    _creating = null;
    if (!ref.mounted) return false;
    // Won by the utterance that asked first, which is the one whose chat this
    // is. Nothing to do but speak into it.
    if (_chatId != null) return true;
    if (id == null) {
      _show(VoiceStatus.failed, error: "Could not start a chat.");
      return false;
    }
    _speakInto(id);
    _show(state.status);
    return true;
  }

  /// The reply, as it is written, turned into sentences and said. Reading it out
  /// of the chat rather than out of the event stream is what keeps voice mode a
  /// view: what is spoken is what the conversation holds.
  void _onChat(ChatViewState? was, ChatViewState chat) {
    if (!state.isOn) return;
    final messages = chat.chat?.messages ?? const <Message>[];
    final last = messages.isEmpty ? null : messages.last;
    if (last == null || last.role != MessageRole.assistant) return;

    if (_reading != last.id) {
      _reading = last.id;
      _sentences.reset();
      // Seeded, not spoken. A reply met for the first time may already be
      // written — entering voice mode over a finished chat, or carrying on an
      // interrupted turn, which is what the resume bar here is for — and only
      // what arrives from now on is new. `add`'s return is what would have
      // been said, and is dropped on purpose.
      _sentences.add(_speakable.of(last.plainText));
      _read = last.parts;
    }
    // An approval, a question, a sub-agent starting: state changes that carry
    // no new words, and there are more of them than there are words. The reply
    // is rebuilt part-list and all on every flush, so identity is exact.
    if (!identical(_read, last.parts)) {
      _read = last.parts;
      _due ??= Timer(_readEvery, _readOn);
    }
    // The tail has no full stop to wait for, so it goes when the turn does —
    // and whatever the timer was still holding goes with it.
    if ((was?.isRunning ?? false) && !chat.isRunning) {
      _readOn();
      _speak(_sentences.flush());
      // A turn that said nothing out loud — one that only ran a command, or was
      // aborted — still ends. Without this the status sticks on `thinking` and
      // the microphone never opens again.
      if (state.status == VoiceStatus.thinking) _show(VoiceStatus.listening);
    }
  }

  /// Whatever has become a whole sentence since the last look.
  void _readOn() {
    _due?.cancel();
    _due = null;
    if (_chatId == null) return;
    final messages = ref.read(chatControllerProvider(_chatId!)).chat?.messages;
    final last = messages == null || messages.isEmpty ? null : messages.last;
    if (last == null || last.id != _reading) return;
    for (final sentence in _sentences.add(_speakable.of(last.plainText))) {
      _speak(sentence);
    }
  }

  void _speak(String text) {
    if (text.trim().isEmpty) return;
    unawaited(_session?.speak(text));
    if (state.status != VoiceStatus.speaking) _show(VoiceStatus.speaking);
  }
}

/// Keyed on the chat, or on null for a session with no chat yet.
///
/// **Auto-disposed, so a session lasts exactly as long as the page watching
/// it.** That is what makes the null key safe to reuse: the next new voice
/// chat builds a controller that has never heard of the last one's chat, with
/// nothing to put back and no window in which the old one could be read. See
/// "Taking turns".
final voiceControllerProvider = NotifierProvider.autoDispose
    .family<VoiceController, VoiceViewState, String?>(VoiceController.new);
