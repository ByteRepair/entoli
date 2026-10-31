import "package:agent_chat/data/local/local_instance.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

void main() {
  group("LocalOptions.fromSettings", () {
    test("carries the cores and cache-count settings", () {
      final options = LocalOptions.fromSettings(
        AppSettings(localModelThreads: 4, localModelKvCachePrompts: 30),
      );
      expect(options.threads, 4);
      expect(options.keptPrompts, 30);

      // Nothing set is the default ten, and the default is on, so a load
      // still keeps prompts; zero is off and is not defaulted away.
      expect(
        LocalOptions.fromSettings(AppSettings()).keptPrompts,
        AppSettings.defaultKvCachePrompts,
      );
      expect(
        LocalOptions.fromSettings(AppSettings()).keptPrompts,
        greaterThan(0),
      );
      expect(
        LocalOptions.fromSettings(
          AppSettings(localModelKvCachePrompts: 0),
        ).keptPrompts,
        0,
      );
    });
  });

  test(
    "a file written under the old name keeps the number it was set to",
    () async {
      final config = tempConfig();
      // The picker counted prompts and said chats. Renaming the key without
      // reading the old one would silently put every existing install back on the
      // default, which is the one thing a relabel must not do.
      await config.documents.write(
        config.settingsFile,
        '{"localModelKvCacheChats": 30}',
      );

      expect(AppSettings.load(config).localModelKvCachePrompts, 30);
    },
  );

  test("the two new settings survive a save and load", () async {
    final config = tempConfig();
    await AppSettings(
      localModelThreads: 2,
      localModelKvCachePrompts: 0,
    ).save(config);
    final back = AppSettings.load(config);
    expect(back.localModelThreads, 2);
    expect(back.localModelKvCachePrompts, 0);
  });
}
