import "package:agent_chat/data/builtin/llm/local_pool_client.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

void main() {
  group("poolOptions", () {
    test("carries the cores and cache-count settings", () {
      final options = poolOptions(AppSettings(
        localModelThreads: 4,
        localModelKvCachePrompts: 30,
      ));
      expect(options.threads, 4);
      expect(options.kvCachePrompts, 30);
    });

    test("null cache-count is the default ten, and zero is off", () {
      expect(poolOptions(AppSettings()).kvCachePrompts, AppSettings.defaultKvCachePrompts);
      expect(poolOptions(AppSettings(localModelKvCachePrompts: 0)).kvCachePrompts, 0);
      // The default is on, so nothing set still reaches the server as caching.
      expect(poolOptions(AppSettings()).kvCachePrompts, greaterThan(0));
    });
  });

  test("a file written under the old name keeps the number it was set to",
      () async {
    final config = tempConfig();
    // The picker counted prompts and said chats. Renaming the key without
    // reading the old one would silently put every existing install back on the
    // default, which is the one thing a relabel must not do.
    await config.documents
        .write(config.settingsFile, '{"localModelKvCacheChats": 30}');

    expect(AppSettings.load(config).localModelKvCachePrompts, 30);
  });

  test("the two new settings survive a save and load", () async {
    final config = tempConfig();
    await AppSettings(localModelThreads: 2, localModelKvCachePrompts: 0).save(config);
    final back = AppSettings.load(config);
    expect(back.localModelThreads, 2);
    expect(back.localModelKvCachePrompts, 0);
  });
}
