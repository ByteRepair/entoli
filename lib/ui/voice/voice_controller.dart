import "dart:async";


import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/background_work.dart";
import "../../domain/models.dart";
import "../../domain/speech_text.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "../../providers.dart";
import "../chat/chat_controller.dart";

/// What voice mode is doing, which is what the circle draws.
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
  });

  final VoiceStatus status;
  final String? error;

  /// The microphone is shut. Not one of the [status] values: a turn can be
  /// running and its reply being read out while the microphone is off, and
  /// those are what the status is for.
  final bool paused;

  /// How loud the microphone is. Held here rather than folded into [status] so
  /// the circle can follow it without the transcript rebuilding for every
  /// audio frame.
  final ValueListenable<double>? level;

  bool get isOn => status != VoiceStatus.off && status != VoiceStatus.failed;
}

/// Voice mode over one chat. **It has no conversation of its own**: it hands
/// what it heard to [ChatController.send] and reads the reply back out of the
/// chat, so a spoken turn is an ordinary turn — same model, same tools, same
/// records in `conv.jsonl` — and leaving voice mode leaves a chat to read.
class VoiceController extends Notifier<VoiceViewState> {
  VoiceController(this.chatId);

  final String chatId;

  VoiceSession? _session;
  StreamSubscription<VoiceEvent>? _events;
  StreamSubscription<BackgroundJob>? _stops;

  final _sentences = SentenceSplitter();

  /// Held rather than read when it is needed: [_shutdown] runs from
  /// `ref.onDispose`, where the ref is already gone.
  late BackgroundWork _work;

  /// Whether the user has shut the microphone. Held rather than read back off
  /// [state], which every `_show` would otherwise have to remember to carry.
  var _paused = false;

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
    ref.listen(chatControllerProvider(chatId), _onChat);
    ref.onDispose(() => unawaited(_shutdown()));
    return const VoiceViewState();
  }

  ChatController get _chat => ref.read(chatControllerProvider(chatId).notifier);

  /// Every state write goes through here. Written out at each call site, the
  /// two `failed` arms silently omitted the level, which is the sort of
  /// difference nobody sees until the circle stops moving.
  void _show(VoiceStatus status, {String? error}) => state = VoiceViewState(
        status: status,
        error: error,
        level: _session?.level,
        paused: _paused,
      );

  Future<void> start() async {
    if (state.isOn) return;
    final settings = ref.read(appSettingsProvider);
    final recognition =
        voiceModelOf<RecognitionModel>(settings.voiceRecognitionModelId);
    final speech = voiceModelOf<SpeechModel>(settings.voiceSpeechModelId);
    if (recognition == null || speech == null) {
      return _show(VoiceStatus.failed,
          error: "Pick a recognition model and a speech model in Settings first.");
    }

    _paused = false;
    _show(VoiceStatus.starting);
    try {
      final session = await ref.read(voiceProvider).start(
            recognition: recognition,
            speech: speech,
            speaker: settings.voiceSpeaker,
          );
      if (!ref.mounted) return unawaited(session.dispose());
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
      _show(VoiceStatus.failed, error: "$e");
    }
  }

  Future<void> stop() async {
    // Mounted first: reading `state` on a disposed notifier throws, and the
    // page's `dispose` reaches this after a container has gone — where
    // `onDispose` has already done the shutting down.
    if (!ref.mounted || state.status == VoiceStatus.off) return;
    await _shutdown();
    if (ref.mounted) _show(VoiceStatus.off);
  }

  /// Shut the microphone, or open it again — Mute, in `VoiceControls`. Voice
  /// mode listens for as long as it is on screen, and until this there was no
  /// way to stop it short of leaving.
  Future<void> setPaused(bool paused) async {
    if (!ref.mounted || !state.isOn || paused == _paused) return;
    _paused = paused;
    await _session?.setListening(!paused);
    if (ref.mounted) _show(state.status);
  }

  /// Shut the reply up without leaving voice mode — Stop, in `VoiceControls`,
  /// and the fallback wherever the platform's echo cancellation is not good
  /// enough for the detector to hear the user over the reply.
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
      case VoiceInterrupted():
        // The session has already gone quiet. Talking over a reply means stop
        // and listen to me, so the turn goes too — which is Stop and then type,
        // in one gesture, and leaves the same aborted turn in the log.
        if (ref.read(chatControllerProvider(chatId)).isRunning) {
          unawaited(_chat.abort());
        }
        _sentences.reset();
      case VoiceFellSilent():
        if (state.status == VoiceStatus.speaking) _show(VoiceStatus.listening);
      case VoiceFailed(:final message):
        _show(VoiceStatus.failed, error: message);
    }
  }

  Future<void> _say(String text) async {
    if (text.trim().isEmpty) return;
    // A turn still running here is one the user talked over. Aborting waits for
    // the turn to be written and closed, so what is said next lands after it
    // rather than into it.
    if (ref.read(chatControllerProvider(chatId)).isRunning) await _chat.abort();
    if (!ref.mounted || !state.isOn) return;
    _show(VoiceStatus.thinking);
    await _chat.send(text);
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
      _sentences.add(speakable(last.plainText));
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
    }
  }

  /// Whatever has become a whole sentence since the last look.
  void _readOn() {
    _due?.cancel();
    _due = null;
    final messages = ref.read(chatControllerProvider(chatId)).chat?.messages;
    final last = messages == null || messages.isEmpty ? null : messages.last;
    if (last == null || last.id != _reading) return;
    for (final sentence in _sentences.add(speakable(last.plainText))) {
      _speak(sentence);
    }
  }

  void _speak(String text) {
    if (text.trim().isEmpty) return;
    unawaited(_session?.speak(text));
    if (state.status != VoiceStatus.speaking) _show(VoiceStatus.speaking);
  }
}

final voiceControllerProvider =
    NotifierProvider.family<VoiceController, VoiceViewState, String>(VoiceController.new);
