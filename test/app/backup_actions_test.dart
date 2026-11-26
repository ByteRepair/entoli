import "package:agent_chat/app/backup_actions.dart";
import "package:agent_chat/data/backup.dart";
import "package:agent_chat/providers.dart";
import "package:entoli_core/model/app_secrets.dart";
import "package:entoli_core/model/app_settings.dart";
import "package:entoli_core/model/background_work.dart";
import "package:entoli_core/model/llm_provider.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late FakeBackgroundWork work;
  late FakeBackupHandoff handoff;
  late FakeAppRestart restart;
  List<BackupWork?>? heldAtRestart;
  late ProviderContainer container;
  late AppSecrets secrets;

  setUp(() {
    work = FakeBackgroundWork();
    handoff = FakeBackupHandoff();
    restart = FakeAppRestart()
      ..onRestart = () => heldAtRestart = [...work.backups];
    secrets = AppSecrets(FakeSecretStore());
    container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(tempConfig()),
        appSecretsProvider.overrideWithValue(secrets),
        backgroundWorkProvider.overrideWithValue(work),
        backupHandoffProvider.overrideWithValue(handoff),
        appRestartProvider.overrideWithValue(restart),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await handoff.dispose();
  });

  test("writing a backup holds the app until it is written", () async {
    final busy = container.read(backupBusyProvider.notifier);
    await busy.run(busy.export);
    expect(work.backups, [BackupWork.writing, null]);
  });

  test("a restore holds the app across its restart", () async {
    final busy = container.read(backupBusyProvider.notifier);
    await busy.run(busy.export);
    work.backups.clear();

    final backup = await openBackup(handoff.saved.single.path);
    await busy.run(() => busy.restore(backup));

    expect(heldAtRestart, [BackupWork.restoring]);
    expect(work.backups, [BackupWork.restoring, null]);
  });

  test(
    "carries the provider keys only where asked, and restores them",
    () async {
      final config = container.read(appConfigProvider);
      final settings = AppSettings.load(config)
        ..llmProviders = const [
          LlmProviderConfig(
            id: "openai",
            api: LlmApi.openai,
            baseUrl: "https://api.openai.com/v1",
          ),
        ];
      await settings.save(config);
      await secrets.setProviderKey("openai", "sk-1");
      final busy = container.read(backupBusyProvider.notifier);
      await busy.run(busy.export);
      expect((await openBackup(handoff.saved.last.path)).providerKeys, isEmpty);

      await (settings..backupProviderKeys = true).save(config);
      await busy.run(busy.export);
      final backup = await openBackup(handoff.saved.last.path);
      expect(backup.providerKeys, {"openai": "sk-1"});

      await secrets.setProviderKey("openai", null);
      await busy.run(() => busy.restore(backup));
      expect(secrets.providerKey("openai"), "sk-1");
    },
  );
}
