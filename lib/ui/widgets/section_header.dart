import "package:flutter/material.dart";

/// A muted paragraph: body small in the variant grey. What [SectionHeader]'s
/// description is, without the header — the explanation a page carries under
/// a title that would only repeat its own name.
Widget mutedParagraph(BuildContext context, String text,
        {TextAlign? textAlign}) =>
    Text(
      text,
      textAlign: textAlign,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );

/// The title over a group of settings, with a line under it saying what the
/// group is for. Shared out of `settings_page.dart` when the Voice category
/// grew a file of its own: a category drawn somewhere else has to look like the
/// ones beside it, and two copies of this would be two answers to the spacing.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (description != null) ...[
              const SizedBox(height: 4),
              mutedParagraph(context, description!),
            ],
          ],
        ),
      );
}
