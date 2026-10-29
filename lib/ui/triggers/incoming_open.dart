import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/reminder_alarms.dart";
import "../../providers.dart";
import "../selection.dart";

/// Wraps the app so tapping a finished trigger's notification opens the chat
/// it ran in. Both routes in, the shape [IncomingAssistant] has: the read at
/// startup catches a tap that launched the app — including the cold start the
/// alarm itself made, whose `main` ran with no activity and no frames — and
/// the stream catches one arriving while it is up.
///
/// The id is claimed before anything is asked of it, and validated against the
/// chat list before being opened: a temporary trigger chat can have been
/// swept between the notification posting and the tap.
class IncomingTriggerOpen extends ConsumerStatefulWidget {
  const IncomingTriggerOpen({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingTriggerOpen> createState() => _IncomingTriggerOpenState();
}

class _IncomingTriggerOpenState extends ConsumerState<IncomingTriggerOpen> {
  StreamSubscription<String>? _taps;

  var _claiming = false;

  @override
  void initState() {
    super.initState();
    _taps = ref.read(reminderAlarmsProvider).openChat.listen((_) => _open());
    // On the first frame rather than in initState: opening a chat needs a
    // Navigator, which does not exist until there is somewhere to put one.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _taps?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    if (_claiming) return;
    _claiming = true;
    ReminderAlarms alarms;
    String? chatId;
    try {
      alarms = ref.read(reminderAlarmsProvider);
      if (!alarms.available) return;
      chatId = await alarms.takeOpenChat();
    } finally {
      _claiming = false;
    }
    if (chatId == null || !mounted) return;
    final chats = await ref.read(chatListProvider.future);
    if (!mounted) return;
    // Gone while the notification sat in the drawer: drop the tap rather than
    // open an error over whatever is on screen.
    if (!chats.any((chat) => chat.id == chatId)) return;
    openChat(context, ref, chatId);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
