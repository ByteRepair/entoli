import "package:agent_chat/app/backup_actions.dart";
import "package:agent_chat/data/backup.dart";
import "package:agent_chat/providers.dart";
import "package:entoli_core/model/app_restart.dart";
import "package:entoli_core/model/background_work.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "../fakes.dart";
import "../harness.dart";

/// A restart that says what was held when it began, and replaces nothing.
class _HeldRestart implements AppRestart {
  _HeldRestart(this.work);

  final FakeBackgroundWork work;
  List<BackupWork?>? heldAtRestart;

  @override
  Future<void> restart({Future<void> Function()? whileStopped}) async {
    heldAtRestart = [...work.backups];
  }
}

void main() {
  late FakeBackgroundWork work;
  late FakeBackupHandoff handoff;
  late _HeldRestart restart;
  late ProviderContainer container;

  setUp(() {
    work = FakeBackgroundWork();
    handoff = FakeBackupHandoff();
    restart = _HeldRestart(work);
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

    expect(restart.heldAtRestart, [BackupWork.restoring]);
    expect(work.backups, [BackupWork.restoring, null]);
  });
}
