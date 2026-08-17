import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "code_block.dart";

/// How a reply's markdown is set. `MarkdownStyleSheet.fromTheme` is the
/// starting point and most of what it answers is right; what is overridden
/// here is the handful of places where its defaults were written for a
/// document rather than for a chat, or read a Material 2 field that M3 leaves
/// null.
///
/// It is a function of the theme alone, which is what lets it live away from
/// the widget that draws with it — and the widget rebuilds it in
/// `didChangeDependencies`, so a palette change reaches it.
MarkdownStyleSheet replyStyleSheet(ThemeData theme) {
  final text = theme.textTheme;
  final body = text.bodyMedium;

  // Headings are a chat's, not a document's. `fromTheme` reaches for the
  // display scale — `headlineSmall` for h1, and `bodyLarge` for h4 down, which
  // is body size with no weight on it, so the last three levels were invisible
  // as headings at all. These step down to the body and stop.
  TextStyle? heading(double size, [FontWeight weight = FontWeight.w600]) =>
      body?.copyWith(fontSize: size, fontWeight: weight, height: 1.3);

  // A heading needs air above it and not below: the paragraph it introduces
  // belongs to it. `fromTheme` gives every level `EdgeInsets.zero`, so a
  // heading sat against the paragraph before it.
  const above = EdgeInsets.only(top: 12);

  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    // Looser than Material's 1.43. A reply is read as prose in a column, where
    // the line to find is the next one down rather than the next word.
    p: body?.copyWith(height: 1.5),
    a: body?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    ),
    code: inlineCodeStyle(theme),
    // `fromTheme` paints this in `cardColor`, which M3 defaults to
    // `colorScheme.surface` — the colour of the page the block is drawn on. It
    // is the one thing the sheet still decides about a `pre`, since the builder
    // draws everything inside the wrapper this decorates.
    codeblockDecoration: codeBlockDecoration(theme),
    h1: heading(21, FontWeight.w700),
    h2: heading(18, FontWeight.w700),
    h3: heading(16),
    h4: heading(body?.fontSize ?? 14),
    h5: heading(body?.fontSize ?? 14),
    h6: heading(body?.fontSize ?? 14),
    h1Padding: above,
    h2Padding: above,
    h3Padding: above,
    h4Padding: above,
    h5Padding: above,
    h6Padding: above,
    // Five pixels of `dividerColor` is a slab across the reply. A rule is a
    // rule.
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
    ),
    blockquoteDecoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(4),
      border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 3)),
    ),
    tableBorder: TableBorder.all(color: theme.colorScheme.outlineVariant),
    // Sixteen either side is a table of two columns running off the width the
    // conversation is read in.
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  );
}
