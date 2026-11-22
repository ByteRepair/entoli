import "../../../data/builtin/llm/providers/presets.dart";
import "../../../domain/llm_provider.dart";
import "../../../providers.dart";
import "package:uuid/uuid.dart";

import "../cli_account.dart" show forgetCliEntry;
import "../controller.dart";
import "../forms/provider.dart";
import "../provider_edit.dart";
import "../spec.dart";

/// The form [provider] is added or edited through, or a new one started on
/// [preset]: the welcome tour's connect.
ProviderForm providerForm(
  SettingReader ref,
  LlmProviderConfig? provider, {
  LlmProvider? preset,
}) {
  final secrets = ref.read(appSecretsProvider);
  final programs = ref.read(cliProgramsProvider);
  return ProviderForm(
    provider,
    preset: preset,
    nameTaken: (name) => ref
        .read(appSettingsProvider)
        .providerNameTaken(name, exceptId: provider?.id),
    storedKey: provider == null ? null : secrets.providerKey(provider.id),
    encrypted: secrets.encrypted,
    newId: const Uuid().v4(),
    forget: (id) => forgetCliEntry(programs, id),
  );
}

/// Saves what [form] was answered with. A typed key is put to the provider
/// first: one it refuses is said on the key, and saving the same again keeps
/// it anyway. [adopt] has it answer new chats at its own defaults.
Future<void> saveProvider(
  SettingReader ref,
  ProviderForm form,
  Map<String, String> answers, {
  bool adopt = false,
}) async {
  final notifier = ref.read(appSettingsProvider.notifier);
  final draft = form.build(answers);
  if (answers["anyway"] != formYes &&
      await checkProviderKey(ref.read(keyCheckProvider), draft) == false) {
    throw FormRefusal(
      "key",
      keyRefused(draft.config),
      anyway: "anyway",
      anywayLabel: "Save anyway",
    );
  }
  await notifier.upsertProvider(
    draft.config,
    setKey: draft.setKey,
    adopt: adopt,
  );
}
