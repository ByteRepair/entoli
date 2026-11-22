import "package:flutter/material.dart";

import "../../domain/chat_search.dart" show searchNeedle;
import "../widgets/nothing.dart";
import "../widgets/page_bar.dart";
import "../widgets/search_field.dart";

/// A list's tags, ticked to filter it: an entry shows only carrying every
/// tag ticked. The ticks are the list's own notifier, so the list behind is
/// already filtered when this page is popped. Each tag says how many entries
/// carry it, and the tags are searched by name.
class MarketplaceTagPickerPage extends StatefulWidget {
  const MarketplaceTagPickerPage({
    super.key,
    required this.tags,
    required this.ticked,
  });

  /// `tagsOf`'s answer: every tag that narrows the list, with its count.
  final List<(String, int)> tags;

  final ValueNotifier<Set<String>> ticked;

  @override
  State<MarketplaceTagPickerPage> createState() =>
      _MarketplaceTagPickerPageState();
}

class _MarketplaceTagPickerPageState extends State<MarketplaceTagPickerPage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<Set<String>>(
      valueListenable: widget.ticked,
      builder: (context, ticks, _) => Scaffold(
        appBar: PageBar(
          title: "Tags",
          actions: [
            if (ticks.isNotEmpty)
              PageAction.text(
                label: "Clear",
                onPressed: () => widget.ticked.value = {},
              ),
          ],
        ),
        body: widget.tags.isEmpty
            ? const Nothing("No tag narrows this list.")
            : Column(
                children: [
                  SearchField(
                    controller: _search,
                    hint: "Search tags",
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: _search,
                      builder: (context, _) {
                        final needle = searchNeedle(_search.text);
                        final shown = [
                          for (final tag in widget.tags)
                            if (tag.$1.toLowerCase().contains(needle)) tag,
                        ];
                        if (shown.isEmpty) {
                          return Nothing(
                            "No tag matches \"${_search.text.trim()}\".",
                          );
                        }
                        return ListView(
                          children: [
                            for (final (tag, count) in shown)
                              CheckboxListTile(
                                value: ticks.contains(tag),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(tag),
                                secondary: Text(
                                  "$count",
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                onChanged: (on) => widget.ticked.value = {
                                  for (final t in ticks)
                                    if (t != tag) t,
                                  if (on ?? false) tag,
                                },
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
