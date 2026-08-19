import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/assistant_view.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
import "../voice/voice_page.dart";

/// Wraps the app so the system's assistant gesture opens a new chat over
/// whatever is on screen. Android's, and only Android's: everywhere else
/// `AssistantLaunch.take` answers false and this is a pass-through.
///
/// Both routes in are needed and neither is enough, the shape [IncomingShares]
/// already has: the read at startup catches the gesture that launched the app,
/// where Kotlin noticed the intent before Dart was listening, and the stream
/// catches one arriving while the app is up — including into an activity whose
/// engine was cached and whose `main` therefore does not run again.
///
/// Where the chat lands is the settings' to say: the project is selected before
/// the chat is made, since `startChat` reads `selectedProjectProvider`.
class IncomingAssistant extends ConsumerStatefulWidget {
  const IncomingAssistant({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingAssistant> createState() => _IncomingAssistantState();
}

class _IncomingAssistantState extends ConsumerState<IncomingAssistant> {
  StreamSubscription<void>? _launches;

  /// One chat at a time: the gesture pressed twice while the first is still
  /// being created would otherwise leave two empty chats, and only the second
  /// on screen.
  var _opening = false;

  @override
  void initState() {
    super.initState();
    _launches = ref.read(assistantLaunchProvider).launched.listen((_) => _open());
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _launches?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    try {
      if (!await ref.read(assistantLaunchProvider).take() || !mounted) return;
      final settings = ref.read(appSettingsProvider);
      selectProject(ref, await _project(settings.assistantProject));
      if (!mounted) return;
      switch (settings.assistantView) {
        // Voice mode asks about its models first and lands on the settings
        // rather than a dead page where they are missing, which is the answer
        // every other way in already gets.
        case AssistantView.voice:
          await startVoiceChat(context, ref);
        case AssistantView.chat:
          await startChat(context, ref);
      }
    } finally {
      _opening = false;
    }
  }

  /// The setting, unless the project it names has since been deleted — in which
  /// case the default one, which is what the settings page has been showing.
  /// Selecting it as it stands would make the chat recreate the directory.
  Future<String?> _project(String? named) async {
    if (named == null) return null;
    final projects = await ref.read(chatRepositoryProvider).listProjects();
    return projects.contains(named) ? named : null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
