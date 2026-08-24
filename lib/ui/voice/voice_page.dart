import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../chat/chat_controller.dart";
import "../chat/widgets/turn_surface.dart";
import "../settings/settings_page.dart";
import "../sidebar/sidebar.dart";
import "../widgets/dialogs.dart";
import "../widgets/nav_drawer.dart";
import "transcript.dart";
import "voice_controller.dart";
import "widgets/transcript_window.dart";
import "widgets/voice_bloom.dart";
import "widgets/voice_controls.dart";

/// Open voice mode over [chatId], or offer the settings that would make it
/// possible. Every way in goes through here — the composer's circle and the
/// assistant gesture's voice view — so there is one answer to what asking for
/// it means with the models not downloaded.
Future<void> openVoice(BuildContext context, WidgetRef ref, String chatId) async {
  if (!await _haveModels(context, ref) || !context.mounted) return;
  await _push(context, chatId);
}

/// A new chat, opened straight into voice mode. **The one place a chat is made
/// before anything is said in it**: every widget on this page is keyed on the
/// chat, down to `voiceControllerProvider`, so there is nothing to defer the
/// way the composer defers. The models are asked about first, which is what
/// keeps the common refusal from making one — see "Nothing selected is a new
/// chat" for what a session abandoned before the first word leaves behind.
Future<void> startVoiceChat(BuildContext context, WidgetRef ref,
    {ChatMeta? meta}) async {
  if (!await _haveModels(context, ref) || !context.mounted) return;
  // [meta] is the new-chat screen's, where the mic sits beside a composer that
  // would have spent it — the same settings, whichever way the chat is started.
  final chatId = await createChat(ref, meta: meta);
  if (chatId == null || !context.mounted) return;
  closeNavDrawer(context);
  await _push(context, chatId);
}

Future<bool> _haveModels(BuildContext context, WidgetRef ref) async {
  if (ref.read(voiceReadyProvider)) return true;
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

/// Voice mode: an orb for what the microphone hears and five scrolling lines
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
    // The session and nothing else: what the chat is doing changes sixty times
    // a second while a reply streams, and none of it reaches this page.
    final voice = ref.watch(voiceControllerProvider(widget.chatId));

    return Scaffold(
      // Nothing in the actions: the bar's own back arrow already pops this
      // route, and leaving is what going back to typing is.
      appBar: AppBar(title: _Title(chatId: widget.chatId)),
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
            _Script(chatId: widget.chatId),
            const SizedBox(height: 16),
            // Bottom-most, where the composer is on the page this stands in
            // for: it is what there is to do here.
            VoiceControls(
              state: voice,
              onMute: _voice.togglePaused,
              onTalk: _voice.talk,
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

/// The chat's name, watched on its own so that a streaming reply does not
/// rebuild the bar to draw the title it already had.
class _Title extends ConsumerWidget {
  const _Title({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(chatControllerProvider(chatId)
        .select((view) => view.chat?.state.title.orUntitled));
    return Text(title ?? "Voice");
  }
}

/// What has been said, and whatever the turn has put on screen above the
/// buttons. Its own widget because it is the half that changes with every
/// delta: the orb and the controls answer to the session, which moves a
/// handful of times a turn, and both are expensive to build.
class _Script extends ConsumerStatefulWidget {
  const _Script({required this.chatId});

  final String chatId;

  @override
  ConsumerState<_Script> createState() => _ScriptState();
}

class _ScriptState extends ConsumerState<_Script> {
  final _transcript = Transcript();

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider(widget.chatId));
    final notifier = ref.read(chatControllerProvider(widget.chatId).notifier);
    final lines = _transcript.of(chat.chat?.messages ?? const <Message>[]);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TranscriptWindow(lines: lines),
        ),
        const SizedBox(height: 12),
        TurnSurface(view: chat, notifier: notifier),
        if (chat.questions.isNotEmpty)
          TurnQuestions(view: chat, notifier: notifier),
      ],
    );
  }
}
