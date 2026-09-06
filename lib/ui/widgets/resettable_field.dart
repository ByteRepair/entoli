import "package:flutter/material.dart";

/// Label of the option that stores `null`, meaning "inherit whatever the next
/// level up decides" — the app default for a chat, the backend default for the
/// app. Always the first entry in a list of options.
const defaultOptionLabel = "Default";

/// Label of the option that stores nothing at all: no provider, no model.
/// Distinct from [defaultOptionLabel], which resolves to something.
const noneOptionLabel = "None";

/// A field paired with a button that puts it back on [resetLabel]. The button
/// is always live: pressed where the field already sits on the reset target
/// it rewrites the same value, which is nothing worth a disabled state — and
/// where a stored pair reads as nothing (a provider removed under it), it is
/// the cleanup.
class ResettableField extends StatelessWidget {
  const ResettableField({
    super.key,
    required this.child,
    required this.onReset,
    this.resetLabel = defaultOptionLabel,
  });

  final Widget child;
  final VoidCallback onReset;

  /// What the reset puts the field back on, named in the tooltip. The
  /// provider-default pickers reset to that rather than to [defaultOptionLabel].
  final String resetLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: child),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IconButton(
            icon: const Icon(Icons.settings_backup_restore),
            tooltip: "Reset to $resetLabel",
            onPressed: onReset,
          ),
        ),
      ],
    );
  }
}

/// A settings field under its caption. Shared so the two settings pages cannot
/// drift apart on spacing.
class LabelledField extends StatelessWidget {
  const LabelledField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            child,
          ],
        ),
      );
}

/// A labelled dropdown whose first entry stores null and means "inherit",
/// paired with the button that puts it back there. [inherited] names what null
/// currently resolves to, so `Default` is never a mystery.
class InheritableDropdown<T> extends StatelessWidget {
  const InheritableDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.inherited,
    this.disabled = const {},
  });

  final String label;
  final T? value;
  final String? inherited;

  /// In the order they should be offered; the `Default` entry leads them.
  final Map<T, String> options;
  final ValueChanged<T?> onChanged;

  /// Options that cannot be selected. The entry is still shown, but greyed
  /// out, so the user knows it exists and what they need to enable it.
  final Set<T> disabled;

  @override
  Widget build(BuildContext context) {
    return LabelledField(
      label: label,
      child: ResettableField(
        onReset: () => onChanged(null),
        child: DropdownButtonFormField<T?>(
          initialValue: value,
          isExpanded: true,
          items: [
            DropdownMenuItem<T?>(
              value: null,
              child: Text(inherited == null
                  ? defaultOptionLabel
                  : "$defaultOptionLabel ($inherited)"),
            ),
            for (final entry in options.entries)
              DropdownMenuItem<T?>(
                value: entry.key,
                enabled: !disabled.contains(entry.key),
                child: Text(entry.value),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
