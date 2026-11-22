import "package:flutter_riverpod/misc.dart" show Override;

import "../app/chat_session.dart" show chatSessionHostProvider;
import "../app/transcript/activities/catalog.dart";
import "../app/transcript/activity.dart" show activityCatalogProvider;
import "../app/transcript/message.dart" show MessageMoment;
import "../ui/chat/activity/card.dart" show nestedTranscriptViewProvider;
import "../ui/chat_session_host.dart";
import "../ui/chat/widgets/message_bubble.dart";

/// The conversation's ports, bound: its activity kinds and how a transcript
/// inside a detail is drawn. `main` and the test harness bind the same list.
final transcriptOverrides = <Override>[
  chatSessionHostProvider.overrideWithValue(RootChatSessionHost()),
  activityCatalogProvider.overrideWithValue(const TranscriptActivities()),
  nestedTranscriptViewProvider.overrideWithValue(
    (nested) => MessageBubble(
      chatId: nested.chatId,
      message: nested.message,
      moment: MessageMoment(waiting: nested.running),
    ),
  ),
];
