import "package:flutter/material.dart";

import "../../../app/transcript/transcript.dart";
import "goal_mark_row.dart";
import "message_text.dart";
import "omada_separator.dart";

/// The conversation's share of a wide window. Past this a reply is a line of
/// text too long to track back to the start of.
const double readableWidth = 760;

/// One row of a conversation. A message is the host's to draw, [message]
/// being given what it holds; the marks between messages are the same
/// wherever the conversation is shown.
class TranscriptRowView extends StatelessWidget {
  const TranscriptRowView(
    this.row, {
    super.key,
    required this.onTapLink,
    required this.message,
  });

  final TranscriptRow row;

  /// Opens a link tapped in model-written markdown: a compaction's summary.
  final ValueChanged<String> onTapLink;

  final Widget Function(MessageRow row) message;

  @override
  Widget build(BuildContext context) => switch (row) {
    final ModeRow row => ConversationSeparator(text: row.text),
    final GoalRow row => GoalMarkRow(row: row),
    CompactionRow(:final summary) => ConversationSeparator(
      text: CompactionRow.text,
      body: _text(summary, isError: false),
    ),
    CompactionFailedRow(:final reason) => ConversationSeparator(
      text: CompactionFailedRow.text,
      body: _text(reason, isError: true),
    ),
    final MessageRow row => message(row),
  };

  Widget _text(String text, {required bool isError}) => MessageText(
    text: text,
    isError: isError,
    isWaiting: false,
    caret: false,
    onTapLink: onTapLink,
  );
}
