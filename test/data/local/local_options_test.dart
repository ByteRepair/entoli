import "package:agent_chat/data/local/local_instance.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:flutter_test/flutter_test.dart";

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
}
