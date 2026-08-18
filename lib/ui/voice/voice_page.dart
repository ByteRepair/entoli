import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../chat/chat_controller.dart";
import "../chat/widgets/turn_surface.dart";
import "transcript.dart";
import "voice_controller.dart";
import "widgets/transcript_window.dart";
import "widgets/voice_circle.dart";

/// Voice mode: a circle for what the microphone hears and five scrolling lines
/// of what has been said, over the chat that was already open. It is a view,
/// not a mode the conversation is in — which is why the turn's own surface and
/// its question panel are the same widgets the chat page draws.
class VoicePage extends ConsumerStatefulWidget {
  const VoicePage({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends ConsumerState<VoicePage> {
  final _transcript = Transcript();

  /// Held rather than read in [dispose], where the ref is no longer safe to
  /// use — and the controller outlives this route anyway, being keyed on the
  /// chat rather than on the screen.
  late final VoiceController _voice =
      ref.read(voiceControllerProvider(widget.chatId).notifier);

  @override
  void initState() {
    super.initState();
    // After the frame: starting loads two models and opens the microphone, and
    // a permission prompt during the first build is one nobody has a screen to
    // answer over yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _voice.start();
    });
  }

  /// Leaving closes the session: the controller is keyed on the chat, so
  /// without this it would listen on with nothing on screen.
  @override
  void dispose() {
    _voice.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(voiceControllerProvider(widget.chatId));
    final chat = ref.watch(chatControllerProvider(widget.chatId));
    final notifier = ref.read(chatControllerProvider(widget.chatId).notifier);
    final lines = _transcript.of(chat.chat?.messages ?? const <Message>[]);

    return Scaffold(
      // Nothing in the actions: the bar's own back arrow already pops this
      // route, and leaving is what going back to typing is.
      appBar: AppBar(title: Text(chat.chat?.state.title.orUntitled ?? "Voice")),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: VoiceCircle(
                  state: voice,
                  // One button, and what it does is whatever stopping means
                  // here: shut the reply up if it is talking, otherwise shut
                  // the microphone — or open it again.
                  onTap: switch (voice.status) {
                    VoiceStatus.speaking => _voice.hush,
                    VoiceStatus.listening ||
                    VoiceStatus.thinking =>
                      () => _voice.setPaused(!voice.paused),
                    _ => null,
                  },
                ),
              ),
            ),
            if (voice.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(
                  voice.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TranscriptWindow(lines: lines),
            ),
            const SizedBox(height: 12),
            TurnSurface(view: chat, notifier: notifier),
            if (chat.questions.isNotEmpty)
              TurnQuestions(view: chat, notifier: notifier),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
