import "package:flutter_riverpod/misc.dart" show Override;

import "../transcript/activities/catalog.dart";
import "../transcript/activity.dart" show activityCatalogProvider;
import "../transcript/message.dart" show MessageMoment;
import "chat/activity/card.dart" show nestedTranscriptViewProvider;
import "chat/widgets/message_bubble.dart";

/// The ports drawing a conversation needs whoever hosts it: its activity
/// kinds and how a transcript inside a detail is drawn. The host's own,
/// `TranscriptHost` and the hand-off, are bound beside these.
final transcriptOverrides = <Override>[
  activityCatalogProvider.overrideWithValue(const TranscriptActivities()),
  nestedTranscriptViewProvider.overrideWithValue(
    (nested) => MessageBubble(
      chatId: nested.chatId,
      message: nested.message,
      moment: MessageMoment(waiting: nested.running),
    ),
  ),
];
