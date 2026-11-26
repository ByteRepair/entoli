import "package:agent_chat/app/backup_actions.dart";
import "package:agent_chat/providers.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "../fakes.dart";

void main() {
  late FakeBackgroundWork work;
  late ProviderContainer container;

  setUp(() {
    work = FakeBackgroundWork();
    container = ProviderContainer(
      overrides: [backgroundWorkProvider.overrideWithValue(work)],
    );
  });

  tearDown(() => container.dispose());

  test("a backup holds the app while it runs", () async {
    final busy = container.read(backupBusyProvider.notifier);
    await busy.run(() async {
      expect(work.backups, [true]);
    });
    expect(work.backups, [true, false]);
  });

  test("a backup that fails lets go all the same", () async {
    final busy = container.read(backupBusyProvider.notifier);
    await expectLater(
      busy.run(() async => throw StateError("disk")),
      throwsStateError,
    );
    expect(work.backups, [true, false]);
  });
}
