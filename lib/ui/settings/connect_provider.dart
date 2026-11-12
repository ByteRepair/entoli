import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../data/builtin/llm/providers/presets.dart";
import "../../providers.dart";
import "../../app/settings/pages/providers.dart"
    show providerForm, saveProvider;
import "../../app/settings/spec.dart" show WidgetReader;
import "form_dialog.dart";
import "../../app/pages/cli_sign_in.dart";
import "../app_pages.dart";

/// Connects [service] the way its user knows it: a CLI is installed and
/// signed in, and an API is its preset's dialog. Either way it is adopted —
/// it answers new chats at its own defaults.
Future<void> connectService(
  BuildContext context,
  WidgetRef ref,
  OfferedByName service,
) => switch (service) {
  CliProvider() => _connectCli(context, ref, service),
  _ => _connectApi(context, ref, service),
};

/// [service]'s form, its preset picked, saved adopted.
Future<void> _connectApi(
  BuildContext context,
  WidgetRef ref,
  LlmProvider service,
) {
  // The reader first: the page that asked can go away while the form is
  // open, and the save must outlive it.
  final reader = WidgetReader(ref);
  final form = providerForm(reader, null, preset: service);
  return showSettingForm(
    context,
    form,
    save: (answers) => saveProvider(reader, form, answers, adopt: true),
  );
}

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
  final programs = ref.read(cliProgramsProvider);
  final existing = ref
      .read(appSettingsProvider)
      .llmProviders
      .where((p) => p.api == service.config.api && p.command == null)
      .firstOrNull;
  // A new entry's id first: its account is kept in a folder named by it.
  final config = existing ?? service.config.copyWith(id: const Uuid().v4());
  final cli = cliProgramOf(programs, config);
  final page = CliSignInAppPage(cli);
  openAppPage(context, page);
  if (!await page.done) {
    if (existing == null) await _forgetDraft(programs, config.id);
    return;
  }
  await notifier.upsertProvider(config, adopt: true);
}

/// A new entry given up on: its folders under every program go, and any
/// sign-in made in them — the dialog may have been switched to another
/// program before it was cancelled.
Future<void> _forgetDraft(List<CliProvider> programs, String id) async {
  for (final cli in programs) {
    await cli.withConfig(cli.config.copyWith(id: id)).forget();
  }
}
