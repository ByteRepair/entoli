import "package:flutter/material.dart";

/// The rounded search box over a list: the sidebar's chats, the marketplace's
/// entries and the project palette's choices. The clear button comes and goes
/// with whether the controller holds anything, listened to here so the field is
/// not rebuilt from above for it — and only when that flips, not on every caret
/// move the controller also reports. [clearButton] off is for a caller that
/// puts its own beside the field, as the sidebar does.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 8),
    this.autofocus = false,
    this.textInputAction = TextInputAction.search,
    this.onSubmitted,
    this.clearButton = true,
  });

  final TextEditingController controller;
  final String hint;
  final EdgeInsets padding;
  final bool autofocus;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool clearButton;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late bool _empty = widget.controller.text.isEmpty;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(SearchField old) {
    super.didUpdateWidget(old);
    if (old.controller == widget.controller) return;
    old.controller.removeListener(_changed);
    widget.controller.addListener(_changed);
    _empty = widget.controller.text.isEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final empty = widget.controller.text.isEmpty;
    if (empty != _empty) setState(() => _empty = empty);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: widget.padding,
      child: TextField(
        controller: widget.controller,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        onSubmitted: widget.onSubmitted,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest,
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.search, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 36,
          ),
          suffixIcon: _empty || !widget.clearButton
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: "Clear search",
                  onPressed: widget.controller.clear,
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
