import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart" show BuildContext;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../app/chat_controller.dart";
import "../voice/transcript.dart";
import "../../app/voice_controller.dart";
import "../../domain/chat_meta.dart";
import "tracking_reader.dart";
import "shell_outbox.dart";
import "shell_answers.dart";
import "shell_turn.dart";

/// How many of the transcript's lines go to the shell: more than its window
/// shows, so there is some of the conversation to scroll back through.
const _keptLines = 40;

/// Voice mode as the native shell draws it, with no page behind it: the
/// session of [chatId] kept for as long as this is open and started as it
/// opens, sent as a [VoiceSnapshot] from the app's state — the session's
/// phase, the microphone's level, the transcript — with the turn's surface
/// over it, and what the client says back run here. Closing it, or Done, is
/// leaving voice mode, which ends the session.
class ShellVoiceSession implements VoiceIntents {
  ShellVoiceSession(
    this._container, {
    required String? chatId,
    required ChatMeta? meta,
    required BuildContext Function() context,
    required this.onDone,
  }) : _provider = voiceControllerProvider(chatId) {
    _keep = _container.listen(_provider, (_, _) {});
    _turn = TurnRunner(context: context, onWithdrawn: null);
    _reader = TrackingReader(_container, _pass);
    _answers.voice.take(this);
    _controller.start(meta: meta);
    _pass();
  }

  final ProviderContainer _container;
  final NotifierProvider<VoiceController, VoiceViewState> _provider;

  /// Run when the user leaves voice mode: the owner lets this go.
  final void Function() onDone;

  late final ShellOutbox _outbox = _container.read(shellOutboxProvider);
  late final ShellAnswers _answers = _container.read(shellAnswersProvider);
  late final ProviderSubscription<VoiceViewState> _keep;
  late final TurnRunner _turn;
  late final TrackingReader _reader;
  final _transcript = Transcript();
  ValueListenable<double>? _level;
  bool _closed = false;

  VoiceController get _controller => _container.read(_provider.notifier);

  void _follow(ValueListenable<double>? level) {
    if (identical(level, _level)) return;
    _level?.removeListener(_sendLevel);
    _level = level?..addListener(_sendLevel);
  }

  void _sendLevel() => _outbox.voiceLevel(_level?.value ?? 0);

  @override
  void mute() => _controller.togglePaused();

  @override
  void talk(bool on) => _controller.talk(on);

  @override
  void stop() => _controller.hush();

  @override
  void done() => onDone();

  void _pass() {
    if (_closed) return;
    _reader.pass(() {
      final voice = _reader.watch(_provider);
      _follow(voice.level);
      final chatId = voice.chatId;
      final chat = chatId == null
          ? null
          : _reader.watch(chatControllerProvider(chatId));
      final lines = _transcript.of(chat?.chat?.messages ?? const <Message>[]);
      _outbox.voice(
        VoiceSnapshot(
          present: true,
          title: chat?.chat?.state.title,
          status: switch (voice.status) {
            VoiceStatus.off => VoicePhase.off,
            VoiceStatus.starting => VoicePhase.starting,
            VoiceStatus.listening => VoicePhase.listening,
            VoiceStatus.thinking => VoicePhase.thinking,
            VoiceStatus.speaking => VoicePhase.speaking,
            VoiceStatus.failed => VoicePhase.failed,
          },
          paused: voice.paused,
          hushed: voice.hushed,
          pushToTalk: voice.pushToTalk,
          on: voice.isOn,
          error: voice.error,
          lines: [
            for (final line in lines.skip(
              lines.length > _keptLines ? lines.length - _keptLines : 0,
            ))
              VoiceLineSnapshot(
                kind: switch (line.kind) {
                  VoiceLineKind.said => VoiceLineRole.said,
                  VoiceLineKind.replied => VoiceLineRole.replied,
                  VoiceLineKind.activity => VoiceLineRole.activity,
                },
                text: line.text,
              ),
          ],
        ),
      );
      // The turn's surface over voice mode, a question in it too.
      if (chat == null || chatId == null) return;
      _answers.turn.cover(_turn);
      _outbox.turn(
        _turn.snapshot(
          _reader,
          chat,
          _reader.read(chatControllerProvider(chatId).notifier),
        ),
      );
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _reader.close();
    _level?.removeListener(_sendLevel);
    _answers.turn.release(_turn);
    if (_answers.voice.release(this)) {
      _outbox.voice(VoiceSnapshot(present: false));
    }
    _keep.close();
  }
}
