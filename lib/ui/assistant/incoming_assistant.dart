import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/assistant_view.dart";
import "../../domain/project.dart";
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
/// Where the chat lands is the settings' to say, and selecting the project is
/// the whole of saying it: the chat arm makes nothing, and the new-chat screen
/// it opens reads `selectedProjectProvider` when the first message creates one.
/// The voice arm creates as it goes, and reads the same provider to do it.
class IncomingAssistant extends ConsumerStatefulWidget {
  const IncomingAssistant({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingAssistant> createState() => _IncomingAssistantState();
}

class _IncomingAssistantState extends ConsumerState<IncomingAssistant> {
  StreamSubscription<void>? _launches;

  /// One claim at a time: the two routes in can both fire for one gesture, and
  /// a launch taken twice is two empty chats. It covers the claim alone rather
  /// than the whole of [_open] — held across the navigation it would still be
  /// set minutes later, while voice mode is on screen, and the gesture arriving
  /// then would be dropped instead of opening anything.
  var _claiming = false;

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
    if (_claiming) return;
    _claiming = true;
    final launched = await ref.read(assistantLaunchProvider).take();
    _claiming = false;
    if (!launched || !mounted) return;

    final settings = ref.read(appSettingsProvider);
    // Resolved rather than taken as read: the project it names may have been
    // deleted, and selecting that would make the chat recreate the directory.
    final projects = await ref.read(projectListProvider.future);
    if (!mounted) return;
    selectProject(ref, projectOrDefault(settings.assistantProject, projects));
    switch (settings.assistantView) {
      // Voice mode asks about its models first and lands on the settings rather
      // than a dead page where they are missing, which is the answer every
      // other way in already gets.
      case AssistantView.voice:
        await startVoiceChat(context, ref);
      case AssistantView.chat:
        openNewChat(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
