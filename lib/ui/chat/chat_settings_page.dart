import "package:flutter/widgets.dart";

import "../../app/pages/chat_settings.dart";
import "../../domain/chat_meta.dart";
import "../app_pages.dart";

/// Open [chatId]'s settings: its title bar and the app's Chat menu.
void openChatSettings(BuildContext context, String chatId) =>
    openAppPage(context, ChatSettingsAppPage(chatId));

/// The settings a chat not made yet will run under, [onSave] handed them on
/// Save; backed out of, nothing is.
void openNewChatSettings(
  BuildContext context, {
  required ChatMeta initial,
  required String? project,
  required void Function(ChatMeta meta) onSave,
}) => openAppPage(
  context,
  NewChatSettingsAppPage(initial: initial, project: project, onSave: onSave),
);
