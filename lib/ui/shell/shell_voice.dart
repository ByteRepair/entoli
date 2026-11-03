import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../chat/chat_controller.dart";
import "../theme.dart";
import "../voice/transcript.dart";
import "../voice/voice_controller.dart";
import "shell_outbox.dart";
import "shell_slots.dart";
import "shell_turn.dart";

/// How many of the transcript's lines go to the shell: more than its window
/// shows, so there is some of the conversation to scroll back through.
const _keptLines = 40;

/// `VoicePage`'s body under the native shell, which draws voice mode over the
/// whole window: the session sent as a [VoiceSnapshot], the microphone's
/// level as it moves, and the turn's surface as [ShellTurnSurface] sends it.
/// The page stays a Flutter route, so leaving it is still popping it, and the
/// session still lives exactly as long as the page.
class ShellVoice extends ConsumerStatefulWidget {
  const ShellVoice({
    super.key,
    required this.voice,
    required this.controller,
    required this.onDone,
  });

  final VoiceViewState voice;
  final VoiceController controller;
  final VoidCallback onDone;

  @override
  ConsumerState<ShellVoice> createState() => ShellVoiceState();
}

class ShellVoiceState extends ConsumerState<ShellVoice>
    implements VoiceIntents {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellSlots _slots = ref.read(shellSlotsProvider);
  final _transcript = Transcript();
  ValueListenable<double>? _level;

  @override
  void initState() {
    super.initState();
    _slots.voice.claim(this);
    _follow(widget.voice.level);
  }

  @override
  void didUpdateWidget(ShellVoice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _follow(widget.voice.level);
  }

  @override
  void dispose() {
    _level?.removeListener(_sendLevel);
    if (_slots.voice.leave(this)) {
      _outbox.voice(VoiceSnapshot(present: false));
    }
    super.dispose();
  }

  /// The microphone's level, straight to the shell: many times a second, and
  /// nothing to compare against.
  void _follow(ValueListenable<double>? level) {
    if (identical(level, _level)) return;
    _level?.removeListener(_sendLevel);
    _level = level?..addListener(_sendLevel);
  }

  void _sendLevel() => _outbox.voiceLevel(_level?.value ?? 0);

  @override
  void mute() => widget.controller.togglePaused();

  @override
  void talk(bool on) => widget.controller.talk(on);

  @override
  void stop() => widget.controller.hush();

  @override
  void done() => widget.onDone();

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    final chatId = voice.chatId;
    final chat = chatId == null
        ? null
        : ref.watch(chatControllerProvider(chatId));
    final driver = chatId == null
        ? null
        : ref.read(chatControllerProvider(chatId).notifier);
    final lines = _transcript.of(chat?.chat?.messages ?? const <Message>[]);
    final brightness = Theme.of(context).brightness;
    _outbox.voice(
      VoiceSnapshot(
        present: true,
        title: chat?.chat?.state.title.orUntitled ?? "Voice",
        status: voice.status.name,
        word: voice.word,
        paused: voice.paused,
        hushed: voice.hushed,
        pushToTalk: voice.pushToTalk,
        on: voice.isOn,
        error: voice.error,
        lines: [
          for (final line in lines.skip(
            lines.length > _keptLines ? lines.length - _keptLines : 0,
          ))
            VoiceLineSnapshot(kind: line.kind.name, text: line.text),
        ],
        heard: heardColour(brightness).toARGB32(),
        spoken: spokenColour(brightness).toARGB32(),
      ),
    );
    // The turn's surface, the chat page's own: over voice mode while it is up,
    // a question in it too, since the chat page's is hidden beneath.
    if (chat == null || driver == null) return const SizedBox.shrink();
    return ShellTurnSurface(view: chat, notifier: driver);
  }
}
