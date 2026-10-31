import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "../../../domain/formatted_text.dart";
import "code_block.dart";
import "math_block.dart";
import "reply_style.dart";

final _builders = <String, MarkdownElementBuilder>{
  ...codeBlockBuilders,
  ...mathBuilders,
};

/// Markdown as the app sets it, wherever it is shown — a reply, a skill, a
/// file in the workspace, a README: the reply's style sheet, code blocks with
/// their bar, formulas drawn, and the grammar the copy reads
/// (`replyExtensionSet`). One widget so that a page showing markdown cannot
/// get some of that and not the rest.
///
/// Owns the style sheet so a parent's build does not rebuild it on every
/// scroll frame; it is rebuilt in `didChangeDependencies`, so a palette change
/// reaches it.
class MarkdownText extends StatefulWidget {
  const MarkdownText(this.data, {super.key, this.onTapLink});

  final String data;

  /// Handed the link's target; a link with none is not reported.
  final ValueChanged<String>? onTapLink;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  late MarkdownStyleSheet _styleSheet;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _styleSheet = replyStyleSheet(Theme.of(context));
  }

  // No `selectable`, and no container of its own: the fragments register with
  // whatever container is above, which is what makes a drag run from the first
  // paragraph to the last — `selectable` builds a `SelectableText` per element,
  // each a selection region to itself, which is what made a selection stop at
  // the paragraph it started in.
  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: widget.data,
    styleSheet: _styleSheet,
    builders: _builders,
    extensionSet: replyExtensionSet,
    bulletBuilder: _bullet,
    onTapLink: (text, href, title) {
      if (href != null) widget.onTapLink?.call(href);
    },
  );

  /// The bullets are chrome, like a code block's bar: on screen, but not part
  /// of what a drag picks up, so what a selection copies reads as the list's
  /// items rather than `•Item`. A builder replaces a numbered list's numbers
  /// too, so it draws them.
  Widget _bullet(MarkdownBulletParameters parameters) =>
      SelectionContainer.disabled(
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            parameters.style == BulletStyle.orderedList
                ? "${parameters.index + 1}."
                : "•",
            style: _styleSheet.listBullet,
            textAlign: TextAlign.center,
          ),
        ),
      );
}
