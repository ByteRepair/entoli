import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:entoli_chat/domain/builtin_project.dart";
import "package:entoli_chat/domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "resettable_field.dart";

/// How long a new chat in [project] lives, where null inherits: the project's
/// Temporary chat, a built-in project's own, then the app's, named in the
/// Default entry.
class TempChatTtlField extends ConsumerWidget {
  const TempChatTtlField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.project,
    this.label = "Temporary chat",
  });

  final TempChatTtl? value;
  final ValueChanged<TempChatTtl?> onChanged;
  final String? project;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inherited = inheritedTempTtl(
      project,
      own: ref.watch(projectSettingsProvider(project)).tempChatTtl,
      app: ref.watch(appSettingsProvider).tempChatTtl,
    );
    return InheritableDropdown<TempChatTtl>(
      label: label,
      value: value,
      inherited: inherited.label,
      options: tempChatTtlLabels,
      onChanged: onChanged,
    );
  }
}
