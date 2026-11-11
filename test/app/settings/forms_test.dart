import "package:agent_chat/app/settings/forms/provider.dart";
import "package:agent_chat/app/settings/forms/trigger.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  final now = DateTime(2026, 11, 11, 9, 41);

  TriggerForm triggerForm([Trigger? trigger]) => TriggerForm(
    trigger,
    now: now,
    projects: const [("", "Default")],
    members: (_) => const ["explore"],
  );

  group("the trigger form", () {
    test("refuses a one-shot time in the past, and no prompt", () {
      final form = triggerForm();
      final answers = {...form.initial, "prompt": "Check the build"};
      expect(form.problem(answers), isNull);
      expect(
        form.problem({...answers, "at": DateTime(2020).toIso8601String()}),
        "Pick a time in the future.",
      );
      expect(
        form.problem({...answers, "prompt": " "}),
        "Write the prompt first.",
      );
    });

    test("asks for paths and a change where it watches files", () {
      final form = triggerForm();
      final files = {...form.initial, "prompt": "Summarise", "kind": "file"};
      expect(form.problem(files), "Name at least one path to watch.");
      expect(
        form.problem({...files, "paths": "project:notes.md", "events": ""}),
        startsWith("Pick what a change is"),
      );
    });

    test("a countdown runs from the save, and fires after it", () {
      final form = triggerForm();
      final made = form.build({
        ...form.initial,
        "kind": "timer",
        "minutes": "45",
        "prompt": "Stand up",
        "member": "explore",
      });
      final source = made.source as TimerSource;
      expect(source.duration, const Duration(minutes: 45));
      expect(source.registeredAt, now);
      expect(made.nextFireAt, now.add(const Duration(minutes: 45)));
      expect(made.member, "explore");
      expect(made.enabled, isTrue);
    });

    test("one the agent registered is shown and not saved", () {
      final form = triggerForm(
        Trigger(
          id: "t",
          name: "",
          prompt: "Ping",
          source: ScheduleSource(at: now.add(const Duration(hours: 1))),
          byAgent: true,
        ),
      );
      expect(form.problem(form.initial), "");
    });
  });

  group("the provider form", () {
    ProviderForm form({LlmProviderConfig? provider, String? stored}) =>
        ProviderForm(provider, nameTaken: (_) => false, storedKey: stored);

    final entry = const LlmProviderConfig(
      id: "p",
      api: LlmApi.openai,
      baseUrl: "http://localhost:1234/v1",
      name: "Mine",
    );

    test("an empty key keeps the stored one, and the choice removes it", () {
      final f = form(provider: entry, stored: "sk-1");
      expect(f.build(f.initial).setKey, isNull);
      expect(f.build({...f.initial, "keep": ""}).setKey, "");
      expect(f.build({...f.initial, "key": "sk-2"}).setKey, "sk-2");
    });

    test("needs a name and an address", () {
      final f = form();
      expect(f.problem(f.initial), "");
      expect(
        f.problem({...f.initial, "name": "Box", "baseUrl": "http://box/v1"}),
        isNull,
      );
    });
  });
}
