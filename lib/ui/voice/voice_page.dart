import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../chat/chat_controller.dart";
import "../chat/widgets/turn_surface.dart";
import "../settings/settings_page.dart";
import "../sidebar/sidebar.dart";
import "../widgets/dialogs.dart";
import "transcript.dart";
import "voice_controller.dart";
import "widgets/transcript_window.dart";
import "widgets/voice_bloom.dart";
import "widgets/voice_controls.dart";

/// Open voice mode over [chatId], or offer the settings that would make it
/// possible. Every way in goes through here — the composer's circle and the
/// empty pane's New Voice Chat — so there is one answer to what pressing one
/// means with the models not downloaded.
///
/// [ready] is `voiceReadyProvider`, and the caller has to have **watched** it:
/// read inside a callback it is false until the installed-models future has
/// resolved, so the first press would offer settings to someone who already
/// has both models.
Future<void> openVoice(
  BuildContext context,
  String chatId, {
  required bool ready,
}) async {
  if (!await _haveModels(context, ready) || !context.mounted) return;
  await _push(context, chatId);
}

/// A new chat, opened straight into voice mode. The models are asked about
/// first: a chat created and then left on screen because there is nothing to
/// say it with is a worse answer than not creating one.
Future<void> startVoiceChat(
  BuildContext context,
  WidgetRef ref, {
  required bool ready,
}) async {
  if (!await _haveModels(context, ready) || !context.mounted) return;
  final chatId = await startChat(context, ref);
  if (chatId == null || !context.mounted) return;
  await _push(context, chatId);
}

Future<bool> _haveModels(BuildContext context, bool ready) async {
  if (ready) return true;
  final go = await confirm(
    context,
    title: "Voice mode needs two models",
    message: "One to hear you and one to answer, downloaded to this device. "
        "Settings has the list.",
    confirmLabel: "Open settings",
  );
  if (go && context.mounted) {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }
  return false;
}

Future<void> _push(BuildContext context, String chatId) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => VoicePage(chatId: chatId)));

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
            Expanded(child: Center(child: VoiceBloom(state: voice))),
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
            const SizedBox(height: 16),
            // Bottom-most, where the composer is on the page this stands in
            // for: it is what there is to do here.
            VoiceControls(
              state: voice,
              onMute: () => _voice.setPaused(!voice.paused),
              onStop: _voice.hush,
              onDone: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
