import "package:flutter/material.dart";

import "../widgets/nothing.dart";

/// The tags a tab's entries carry, ticked to filter its list. An entry shows
/// only when it carries every tag ticked, and no ticked tag filters nothing.
/// The ticks are the marketplace page's own notifier for the tab, mutated in
/// place — the list behind is already filtered when this page is popped. The
/// tag list is what the page computed at the filter icon's press; the count
/// is how many entries carry a tag, which is the first thing to read where
/// one of them sits on most of the list.
class MarketplaceTagPickerPage extends StatelessWidget {
  const MarketplaceTagPickerPage({
    super.key,
    required this.tags,
    required this.ticked,
  });

  /// Every tag the tab's entries carry, with each one's entry count —
  /// `tagsOf`'s answer, alphabetical.
  final List<(String, int)> tags;

  final ValueNotifier<Set<String>> ticked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Tags"),
        actions: [
          ValueListenableBuilder<Set<String>>(
            valueListenable: ticked,
            builder: (context, ticks, _) => ticks.isEmpty
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () => ticked.value = {},
                    child: const Text("Clear"),
                  ),
          ),
        ],
      ),
      body: tags.isEmpty
          ? const Nothing("This tab's entries carry no tags yet.")
          : ValueListenableBuilder<Set<String>>(
              valueListenable: ticked,
              builder: (context, ticks, _) => ListView(
                children: [
                  for (final (tag, count) in tags)
                    CheckboxListTile(
                      value: ticks.contains(tag),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(tag),
                      secondary: Text(
                        "$count",
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onChanged: (selected) {
                        final next = {...ticks};
                        if (selected ?? false) {
                          next.add(tag);
                        } else {
                          next.remove(tag);
                        }
                        ticked.value = next;
                      },
                    ),
                ],
              ),
            ),
    );
  }
}
