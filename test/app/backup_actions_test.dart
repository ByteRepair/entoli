import "package:agent_chat/app/backup_actions.dart";
import "package:agent_chat/data/backup.dart";
import "package:agent_chat/providers.dart";
import "package:entoli_core/model/background_work.dart";
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

  setUp(() {
    work = FakeBackgroundWork();
    handoff = FakeBackupHandoff();
    restart = FakeAppRestart()
      ..onRestart = () => heldAtRestart = [...work.backups];
    container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(tempConfig()),
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
}
