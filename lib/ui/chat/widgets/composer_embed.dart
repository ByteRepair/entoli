import "package:flutter/material.dart";

import "../../../domain/formatted_text.dart";
import "../../../domain/quote.dart";

/// Something in the composer that is not typed text: drawn in the field as a
/// widget, sent as the markdown it stands for. The field holds one character
/// in its place (see `ComposerController`), so the caret steps over it,
/// Backspace deletes it and undo brings it back, all as the field's own
/// editing does for a letter.
///
/// A new kind of thing to put in a message is a subclass, and a reader in
/// `ComposerController.readers` where a message taken back should come back
/// as one.
abstract class ComposerEmbed {
  const ComposerEmbed();

  /// A block sits on a line of its own and sends as a paragraph of its own,
  /// with a blank line either side whatever was typed around it. An inline one
  /// sends exactly where it is.
  bool get block => true;

  /// What this is in the message sent.
  String get markdown;

  /// Drawn where its character is. [remove] takes it out of the field.
  Widget build(BuildContext context, VoidCallback remove);
}

/// Reads one paragraph of a message back into the embed that wrote it, or
/// null where it is not one of its.
typedef EmbedReader = ComposerEmbed? Function(String block);

/// A passage of the conversation being answered.
class QuoteEmbed extends ComposerEmbed {
  const QuoteEmbed(this.quote);

  final Quote quote;

  static QuoteEmbed? read(String block) {
    final quote = Quote.tryParse(block);
    return quote == null ? null : QuoteEmbed(quote);
  }

  @override
  String get markdown => quote.markdown;

  @override
  Widget build(BuildContext context, VoidCallback remove) =>
      QuoteCard(quote: quote, onRemove: remove);
}

/// A quote as the composer draws it: the passage under the handle it answers,
/// cut to a few lines — the whole of it is in the message, and the card only
/// has to say which passage this is.
class QuoteCard extends StatelessWidget {
  const QuoteCard({super.key, required this.quote, required this.onRemove});

  final Quote quote;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (quote.handle != null)
                  Text(
                    quote.handle!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                Text(
                  formattedTextOf(quote.text).trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close),
            iconSize: 16,
            color: muted,
            // Its own size rather than a 48dp touch target, which would make
            // every one-line card twice the height of its line.
            style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size.square(28),
              fixedSize: const Size.square(28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            tooltip: "Remove quote",
          ),
        ],
      ),
    );
  }
}
