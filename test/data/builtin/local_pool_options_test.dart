import "package:agent_chat/data/builtin/llm/local_pool_client.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

void main() {
  group("poolOptions", () {
    test("carries the cores and cache-count settings", () {
      final options = poolOptions(AppSettings(
        localModelThreads: 4,
        localModelKvCacheChats: 30,
      ));
      expect(options.threads, 4);
      expect(options.kvCacheChats, 30);
    });

    test("null cache-count is the default ten, and zero is off", () {
      expect(poolOptions(AppSettings()).kvCacheChats, AppSettings.defaultKvCacheChats);
      expect(poolOptions(AppSettings(localModelKvCacheChats: 0)).kvCacheChats, 0);
      // The default is on, so nothing set still reaches the server as caching.
      expect(poolOptions(AppSettings()).kvCacheChats, greaterThan(0));
    });
  });

  test("the two new settings survive a save and load", () async {
    final config = tempConfig();
    await AppSettings(localModelThreads: 2, localModelKvCacheChats: 0).save(config);
    final back = AppSettings.load(config);
    expect(back.localModelThreads, 2);
    expect(back.localModelKvCacheChats, 0);
  });
}
