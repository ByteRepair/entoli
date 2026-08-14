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
