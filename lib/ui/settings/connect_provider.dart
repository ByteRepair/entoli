import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/llm_provider.dart";
import "../../providers.dart";
import "../widgets/provider_dialog.dart";
import "cli_sign_in_dialog.dart";

/// [promptForProvider] with what the app knows filled in, saved through the
/// settings notifier: an entry being edited keeps its id, and one being
/// added, preset or not, has none until the notifier gives it one. The one
/// way in for the Providers page and the welcome tour alike; [adopt] is the
/// notifier's own, the tour's choosing a service by name.
Future<void> editProvider(
  BuildContext context,
  WidgetRef ref, {
  LlmProviderConfig? initial,
  String title = "Add provider",
  bool adopt = false,
}) async {
  // Notifier first: the page that asked can go away while the dialog is
  // open, and the save must outlive it rather than resume on a defunct ref.
  final notifier = ref.read(appSettingsProvider.notifier);
  final secrets = ref.read(appSecretsProvider);
  final saved = await promptForProvider(
    context,
    initial: initial,
    storedKey: initial == null ? null : secrets.providerKey(initial.id),
    nameTaken: (name) => ref
        .read(appSettingsProvider)
        .providerNameTaken(name, exceptId: initial?.id),
    encrypted: secrets.encrypted,
    title: title,
    openLink: ref.read(linkOpenerProvider).open,
    checkKey: ref.read(keyCheckProvider),
    cliAccount: (api) => CliAccountSection(api: api),
  );
  if (saved == null) return;
  await notifier.upsertProvider(
    saved.config,
    setKey: saved.setKey,
    adopt: adopt,
  );
}

/// Connects [service] the way its user knows it: a CLI is installed and
/// signed in, and an API is its preset's dialog. Either way it is adopted —
/// it answers new chats at its own defaults.
Future<void> connectService(
  BuildContext context,
  WidgetRef ref,
  OfferedByName service,
) => switch (service) {
  CliProvider() => _connectCli(context, ref, service),
  _ => editProvider(
    context,
    ref,
    initial: service.config,
    title: "Connect ${service.displayName}",
    adopt: true,
  ),
};

/// [service]'s program, Entoli's own copy of it installed where it is not
/// yet and signed in where it is not yet, added once it is — or, where an
/// entry for it is already configured, that entry adopted rather than a
/// second one added beside it.
Future<void> _connectCli(
  BuildContext context,
  WidgetRef ref,
  OfferedByName service,
) async {
  // Notifier first: the page that asked can go away while the dialog is
  // open, and the save must outlive it.
  final notifier = ref.read(appSettingsProvider.notifier);
  final cli = ref
      .read(cliProgramsProvider)
      .firstWhere((c) => c.config.api == service.config.api);
  final ready = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CliSignInDialog(cli: cli),
  );
  if (ready != true) return;
  final existing = ref
      .read(appSettingsProvider)
      .llmProviders
      .where((p) => p.api == cli.config.api && p.command == null)
      .firstOrNull;
  await notifier.upsertProvider(existing ?? cli.config, adopt: true);
}
