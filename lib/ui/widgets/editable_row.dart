import "package:flutter/material.dart";

/// One entry in an editable list: tap the row to change it, the cross to drop
/// it. The provider list and the environment variable lists are the same
/// affordance over different data, which is what makes this shared.
class EditableRow extends StatelessWidget {
  const EditableRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.removeLabel,
    required this.onTap,
    required this.onRemove,
    this.detail,
  });

  final String title;
  final String subtitle;
  final String removeLabel;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  /// Drawn under the subtitle, for what one kind of entry has to say beyond
  /// a line — a provider's allowances.
  final Widget? detail;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text(title),
    subtitle: detail == null
        ? Text(subtitle)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(subtitle), detail!],
          ),
    onTap: onTap,
    trailing: IconButton(
      icon: const Icon(Icons.close),
      tooltip: removeLabel,
      onPressed: onRemove,
    ),
  );
}
