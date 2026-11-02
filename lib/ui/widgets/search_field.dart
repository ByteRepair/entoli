import "package:flutter/material.dart";

/// The rounded search box over a list: the sidebar's chats, the marketplace's
/// entries and the project palette's choices. The clear button comes and goes
/// with what the controller holds, listened to here so the field is not
/// rebuilt from above for it.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 8),
    this.autofocus = false,
    this.textInputAction = TextInputAction.search,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final EdgeInsets padding;
  final bool autofocus;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          autofocus: autofocus,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            hintText: hint,
            prefixIcon: const Icon(Icons.search, size: 20),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 36,
            ),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: "Clear search",
                    onPressed: controller.clear,
                  ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 36,
              minHeight: 36,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// The small caption a list's groups sit under — the sidebar's dates, the
/// marketplace's remote half, the palette's sections.
class ListHeading extends StatelessWidget {
  const ListHeading(this.text, {super.key, this.top = 16});

  final String text;

  /// The gap above, which is the one thing the lists differ on.
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top, 20, 6),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
