import "dart:typed_data";

import "package:flutter/material.dart";

/// The bar under an install: the one Install button, dead while
/// [installing] runs and showing the spinner for it. Shared by the
/// skill-install preview page and the marketplace's entry preview, so the
/// install motion lives in one file instead of two.
class InstallBar extends StatelessWidget {
  const InstallBar({
    super.key,
    required this.installing,
    required this.label,
    required this.onPressed,
  });

  final bool installing;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: installing ? null : onPressed,
          icon: installing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.install_desktop),
          label: Text(installing ? "Installing…" : label),
        ),
      ),
    );
  }
}

/// A skill package's files beside SKILL.md: the row of icon and name, under
/// the "Files" caption. Shared by the skill view, the skill-install preview
/// and the marketplace's entry preview; [sizeOf] is the optional column
/// after the name, which the skill view passes and the others leave out.
class PackageFileList extends StatelessWidget {
  const PackageFileList({super.key, required this.entries, this.sizeOf});

  final List<(String, Uint8List)> entries;
  final String Function(int bytes)? sizeOf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Files", style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final (name, bytes) in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(name, style: theme.textTheme.bodyMedium)),
                if (sizeOf != null)
                  Text(sizeOf!(bytes.length), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
  }
}