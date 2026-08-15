import "package:flutter/material.dart";

/// Label of the option that stores `null`, meaning "inherit whatever the next
/// level up decides" — the app default for a chat, the backend default for the
/// app. Always the first entry in a list of options.
const defaultOptionLabel = "Default";

/// A field paired with a button that puts it back on [defaultOptionLabel].
class ResettableField extends StatelessWidget {
  const ResettableField({super.key, required this.child, required this.onReset, this.isDefault = false});

  final Widget child;
  final VoidCallback onReset;
  final bool isDefault;

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
            tooltip: "Reset to $defaultOptionLabel",
            onPressed: isDefault ? null : onReset,
          ),
        ),
      ],
    );
  }
}

/// The "inherit" entry that leads every option list.
DropdownMenuItem<String?> defaultMenuItem() =>
    const DropdownMenuItem<String?>(value: null, child: Text(defaultOptionLabel));

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
  });

  final String label;
  final T? value;
  final String? inherited;

  /// In the order they should be offered; the `Default` entry leads them.
  final Map<T, String> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          ResettableField(
            isDefault: value == null,
            onReset: () => onChanged(null),
            child: DropdownButtonFormField<T?>(
              initialValue: value,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: [
                DropdownMenuItem<T?>(
                  value: null,
                  child: Text(inherited == null
                      ? defaultOptionLabel
                      : "$defaultOptionLabel ($inherited)"),
                ),
                for (final entry in options.entries)
                  DropdownMenuItem<T?>(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
