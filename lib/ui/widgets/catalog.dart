import "package:flutter/material.dart";

import "../../domain/download.dart";
import "dialogs.dart";
import "../../core/formatting.dart";
import "resettable_field.dart";

// What both catalogs on the settings pages are made of: a row per thing that
// can be downloaded, the one button that applies to it, and the picker over
// what is installed. The voice models and the Linux the agent runs commands in
// are different enough to be two catalogs and identical in all of this.

/// One entry as a row: what it is, what it costs, and the button. Everything
/// optional here is a line that only some rows have — a note, a failure, a bar
/// — and the three-line height follows from whether any of them is there rather
/// than being decided at each call site.
class CatalogTile extends StatelessWidget {
  const CatalogTile({
    super.key,
    required this.title,
    required this.summary,
    required this.trailing,
    this.note,
    this.failure,
    this.progress,
  });

  /// A widget rather than a string, since a row may carry a badge beside its
  /// name.
  final Widget title;

  /// The one line under the name: what it holds, and what it costs.
  final String summary;

  /// Anything else worth knowing before downloading it. Null where the name and
  /// the summary say enough.
  final String? note;

  /// Why the last attempt stopped, in the error colour.
  final String? failure;

  /// The bar, where one is being fetched right now.
  final DownloadProgress? progress;

  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return ListTile(
      isThreeLine: note != null || failure != null || progress != null,
      title: title,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(summary),
          if (note != null)
            Text(note!, style: small?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (failure != null)
            Text(failure!, style: small?.copyWith(color: theme.colorScheme.error)),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
                value: progress!.unpacking ? null : progress!.fraction),
            const SizedBox(height: 4),
            Text(
              progress!.unpacking
                  ? "Unpacking…"
                  : "${formatSize(progress!.received)} of ${formatSize(progress!.total)}",
              style: small,
            ),
          ],
        ],
      ),
      trailing: trailing,
    );
  }
}

/// The one button a row gets: download, cancel, or delete, and **never more
/// than one at a time** — which is the whole of what this class is for. A null
/// [onDownload] is a row this device cannot fetch, drawn dead rather than left
/// out, so the reader can see it exists.
///
/// Deleting asks first, here rather than at each call site: what is being
/// agreed to differs between catalogs and *that it is asked at all* does not.
/// [onDelete] is reached only on a yes.
class CatalogAction extends StatelessWidget {
  const CatalogAction({
    super.key,
    required this.downloading,
    required this.installed,
    required this.onCancel,
    required this.onDelete,
    required this.deleteTitle,
    required this.deleteMessage,
    this.onDownload,
  });

  final bool downloading;
  final bool installed;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final String deleteTitle;
  final String deleteMessage;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    if (downloading) {
      return IconButton(
        icon: const Icon(Icons.close),
        tooltip: "Cancel",
        onPressed: onCancel,
      );
    }
    if (installed) {
      return IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: "Delete",
        onPressed: () => _confirmDelete(context),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: "Download",
      onPressed: onDownload,
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await confirm(
      context,
      title: deleteTitle,
      message: deleteMessage,
      confirmLabel: "Delete",
      destructive: true,
    );
    if (ok) onDelete();
  }
}

/// A field over what is installed, and **not** over the catalog: a picker
/// offering something that has to be downloaded first is a choice that fails
/// when it is used rather than when it is made.
///
/// Not [InheritableDropdown], which looks the same and means something else —
/// there null is "inherit whatever the level above says" and comes with a reset
/// button. Here it is either a choice of its own ([none], as Android is for the
/// terminal) or nothing picked yet, and neither has a level above it.
class InstalledPicker extends StatelessWidget {
  const InstalledPicker({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onPick,
    this.none,
    this.description,
  });

  final String label;

  /// Material's own helper text under the field, the way the LLM pickers word
  /// what their options mean.
  final String? description;

  /// Id to name, in the order they should be offered.
  final Map<String, String> options;

  final String? value;
  final ValueChanged<String?> onPick;

  /// What the null entry reads as, where null is an answer rather than an
  /// absence. Null leaves it a hint instead, which is a field nothing is picked
  /// in.
  final String? none;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty && none == null) {
      return LabelledField(
        label: label,
        child: Text("Nothing downloaded yet.",
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return LabelledField(
      label: label,
      child: DropdownButtonFormField<String?>(
        isExpanded: true,
        decoration: InputDecoration(helperText: description),
        // A setting naming something since deleted is a value no item carries,
        // which `DropdownButton` asserts on. One place answers that for both
        // catalogs.
        initialValue: options.containsKey(value) ? value : null,
        hint: const Text("None"),
        items: [
          if (none != null)
            DropdownMenuItem<String?>(value: null, child: Text(none!)),
          for (final entry in options.entries)
            DropdownMenuItem<String?>(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: onPick,
      ),
    );
  }
}
