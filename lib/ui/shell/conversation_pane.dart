import "package:flutter/material.dart";

import "../chat/chat_page.dart";

/// What Flutter draws inside the native shell: the open conversation, with the
/// shell's bars as its padding so it scrolls under them. The pages it pushes
/// draw over it inside the same view.
class ConversationPane extends StatelessWidget {
  const ConversationPane({super.key});

  @override
  Widget build(BuildContext context) => const ChatPage();
}
