import "package:flutter_riverpod/misc.dart" show Override;

import "../app/transcript/activities/catalog.dart";
import "../app/transcript/activity.dart" show activityCatalogProvider;
import "../app/transcript/code.dart";
import "../app/transcript/formula.dart";
import "../ui/chat/activity/activity.dart" show nestedTranscriptViewProvider;
import "../ui/chat/widgets/message_bubble.dart";
import "code_grammars.dart";
import "formula_png.dart";

/// The conversation's ports, bound: its activity kinds, the typesetter, the
/// highlighter, and how a transcript inside a detail is drawn. `main` and
/// the test harness bind the same list.
final transcriptOverrides = <Override>[
  activityCatalogProvider.overrideWithValue(const TranscriptActivities()),
  formulaRendererProvider.overrideWithValue(
    CachedFormulaRenderer(const MathPngRenderer()),
  ),
  codeHighlighterProvider.overrideWithValue(const GrammarHighlighter()),
  nestedTranscriptViewProvider.overrideWithValue(
    (nested) => MessageBubble(
      chatId: nested.chatId,
      message: nested.message,
      isWaiting: nested.running,
    ),
  ),
];
