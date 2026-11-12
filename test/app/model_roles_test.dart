import "package:agent_chat/data/local/apple_fm.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/providers.dart";
import "package:flutter_test/flutter_test.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  const other = LlmProviderConfig(
    id: "other",
    name: "Other",
    api: LlmApi.openai,
    baseUrl: "https://o.example/v1",
    defaultModelId: "big",
    defaultLightModelId: "small",
  );

  test(
    "on an Apple device, titles and verdicts stay on its own model",
    () async {
      final app = TestApp.create(appleFm: const AppleFm(AppleFmProbe("ok")));
      addTearDown(app.dispose);
      final notifier = app.container.read(appSettingsProvider.notifier);
      AppSettings settings() => app.container.read(appSettingsProvider);

      expect(settings().titleProviderId, appleProviderId);
      expect(settings().classifierProviderId, appleProviderId);

      await notifier.upsertProvider(testProvider, adopt: true);
      expect(settings().defaultProviderId, testProviderId);
      expect(settings().titleProviderId, appleProviderId);
      expect(settings().classifierProviderId, appleProviderId);
    },
  );

  test("a removed provider's roles are filled by the next one added", () async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    final notifier = app.container.read(appSettingsProvider.notifier);
    AppSettings settings() => app.container.read(appSettingsProvider);

    await notifier.upsertProvider(testProvider);
    expect(settings().classifierProviderId, testProviderId);

    await notifier.setProviders(const []);
    expect(settings().classifierProviderId, isNull);
    expect(settings().titleProviderId, isNull);

    await notifier.upsertProvider(other);
    expect(settings().defaultProviderId, other.id);
    expect(settings().titleProviderId, other.id);
    expect(settings().memoryProviderId, other.id);
    expect(settings().classifierProviderId, other.id);
  });
}
