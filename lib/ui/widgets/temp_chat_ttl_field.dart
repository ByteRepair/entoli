import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/builtin_project.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "resettable_field.dart";

/// A chat's temporary-chat TTL override. Null means inherit the project (if
/// set) or app default; the resolved value is named in the Default entry.
///
/// Shared by the chat settings page and the trigger editor: a new chat
/// is a chat, and this is the field that decides how long one lives.
class TempChatTtlField extends ConsumerWidget {
  const TempChatTtlField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.project,
  });

  final TempChatTtl? value;
  final ValueChanged<TempChatTtl?> onChanged;
  final String? project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectTtl = ref.watch(projectSettingsProvider(project)).tempChatTtl;
    final appTtl = ref.watch(appSettingsProvider).tempChatTtl;
    // Mirrors the tail of `ChatRepository._resolveTempTtl` minus the chat's own
    // value, which `value` is editing: the inherited default a null resolves to.
    return InheritableDropdown<TempChatTtl>(
      label: "Temporary chat",
      value: value,
      inherited:
          (projectTtl ?? builtinProjectOf(project)?.tempChatTtl ?? appTtl)
              .label,
      options: tempChatTtlLabels,
      onChanged: onChanged,
    );
  }
}
