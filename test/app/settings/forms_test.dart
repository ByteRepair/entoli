import "package:agent_chat/app/model_role.dart";
import "package:agent_chat/app/settings/forms/model.dart";
import "package:agent_chat/app/settings/forms/provider.dart";
import "package:agent_chat/app/settings/forms/trigger.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart"
    show CliProvider, HostCliGuest, LlmProvider;
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/model_info.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  final now = DateTime(2026, 11, 11, 9, 41);

  TriggerForm triggerForm([Trigger? trigger]) => TriggerForm(
    trigger,
    now: now,
    projects: const [("", "Default")],
    members: (_) => const ["explore"],
    inheritedTtl: (_) => TempChatTtl.off,
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
    ProviderForm form({
      LlmProviderConfig? provider,
      String? stored,
      LlmProvider? preset,
      bool Function(String)? taken,
      Future<void> Function(String id)? forget,
    }) => ProviderForm(
      provider,
      preset: preset,
      nameTaken: taken ?? (_) => false,
      storedKey: stored,
      newId: "new",
      forget: forget,
    );

    final entry = const LlmProviderConfig(
      id: "p",
      api: LlmApi.openai,
      baseUrl: "http://localhost:1234/v1",
      name: "Mine",
    );

    Map<String, String> picked(ProviderForm f, String preset) => {
      ...f.initial,
      "preset": preset,
    };

    test("a new one starts on the presets alone, the hand-typed one last", () {
      final f = form();
      final picker = f.fields(f.initial).single as FormChoice;
      expect(picker.cards, isTrue);
      expect(f.problem(f.initial), "");
      final groups = [for (final o in picker.options) o.group];
      expect(groups.first, "Paid");
      expect(groups, contains("Free, at a cost to privacy"));
      expect(picker.options.last.label, "Custom…");
    });

    test("a free tier is agreed to before anything else is asked", () {
      final f = form();
      final google = picked(f, "Google Gemini");
      final consent = f.fields(google).whereType<FormConsent>().single;
      expect(consent.message, contains("free tier"));
      expect(f.fields(google).whereType<FormText>(), isEmpty);
      expect(f.problem(google), "");

      final agreed = {...google, consent.id: formYes};
      expect(f.fields(agreed).whereType<FormConsent>(), isEmpty);
      expect(
        f.fields(agreed).whereType<FormText>().map((t) => t.id),
        contains("key"),
      );
    });

    test("a preset asks for its key in plain words, its endpoint folded", () {
      final f = form();
      final ollama = picked(f, "Ollama Cloud");
      final fields = f.fields(ollama);
      final link = fields.whereType<FormLink>().first;
      expect(link.prominent, isTrue);
      expect(link.label, "Get a key from Ollama Cloud");
      final key = fields.whereType<FormText>().singleWhere(
        (t) => t.id == "key",
      );
      expect(key.label, "Access key");
      expect(key.secret, isTrue);
      expect(
        fields.whereType<FormText>().map((t) => t.id),
        isNot(contains("baseUrl")),
      );

      final open = {...ollama, "advanced": formYes};
      final baseUrl = f
          .fields(open)
          .whereType<FormText>()
          .singleWhere((t) => t.id == "baseUrl");
      expect(baseUrl.hint, "https://ollama.com/v1");

      final made = f.build({...ollama, "key": "sk-ollama"});
      expect(made.config.displayName, "Ollama Cloud");
      expect(made.config.baseUrl, "https://ollama.com/v1");
      expect(made.config.catalogId, "ollama-cloud");
      expect(made.config.id, "new");
      expect(made.setKey, "sk-ollama");
    });

    test("a preset already configured needs a name of its own", () {
      final f = form(taken: (name) => name == "Ollama Cloud");
      final ollama = picked(f, "Ollama Cloud");
      expect(f.problem(ollama), "");
      expect(f.problem({...ollama, "name": "Ollama work"}), isNull);
    });

    test("a program asks for its sign-in and what it runs under", () {
      final f = form();
      final claude = picked(f, "Claude CLI");
      final fields = f.fields(claude);
      final signIn = fields.whereType<FormSignIn>().single;
      // Signed in under the id the entry will be saved with.
      expect(signIn.config.id, "new");
      expect(signIn.config.api, LlmApi.claudeCli);
      expect(fields.whereType<FormEntries>().single.id, "env");
      expect(
        fields.whereType<FormText>().singleWhere((t) => t.id == "command").file,
        isTrue,
      );
      final made = f.build({...claude, "env": "A=1\nB=two=2"});
      expect(made.config.env, {"A": "1", "B": "two=2"});
      expect(made.setKey, isNull);
    });

    test("a program with nowhere to run is not offered", () {
      CliProvider.platformGuest = null;
      addTearDown(() => CliProvider.platformGuest = const HostCliGuest());
      final f = form();
      final picker = f.fields(f.initial).single as FormChoice;
      expect(picker.options.map((o) => o.label), isNot(contains("Claude CLI")));
    });

    test(
      "left unsaved, a new entry's sign-ins go and an edit's stay",
      () async {
        final forgotten = <String>[];
        Future<void> forget(String id) async => forgotten.add(id);
        final adding = form(forget: forget);
        await adding.dismissed(adding.initial);
        final editing = form(provider: entry, forget: forget);
        await editing.dismissed(editing.initial);
        expect(forgotten, ["new"]);
      },
    );

    test("an empty key keeps the stored one, and the choice removes it", () {
      final f = form(provider: entry, stored: "sk-1");
      expect(f.build(f.initial).setKey, isNull);
      expect(f.build({...f.initial, "keep": ""}).setKey, "");
      expect(f.build({...f.initial, "key": "sk-2"}).setKey, "sk-2");
      // The stored key is never put back into the field.
      expect(f.initial["key"], "");
    });

    test("over no stored key, an empty field clears", () {
      final f = form(provider: entry);
      expect(f.build(f.initial).setKey, "");
    });

    test("one typed in by hand needs a name and an address", () {
      final f = form();
      final custom = picked(f, "");
      expect(f.problem(custom), "");
      expect(f.problem({...custom, "name": "nameless"}), "");
      expect(
        f.problem({...custom, "name": "Box", "baseUrl": "http://box/v1"}),
        isNull,
      );
    });

    test("an edit keeps its id", () {
      final f = form(provider: entry);
      expect(f.build({...f.initial, "name": "Renamed"}).config.id, "p");
    });
  });

  group("the model form", () {
    ModelForm form({ModelRole role = ModelRole.agent, ModelInfo? model}) =>
        ModelForm(
          role: role,
          providers: const [("p1", "Box"), ("p2", "Cloud")],
          providerId: model == null ? null : "p2",
          model: model,
        );

    test("a chat model keeps what it can do, a speech model none of it", () {
      final f = form();
      final chat = f.build({
        ...f.initial,
        "id": "tuned-1",
        "caps": "toolCall,readsImages",
      });
      expect(chat.providerId, "p1");
      expect(chat.info.toolCall, isTrue);
      expect(chat.info.readsImages, isTrue);
      expect(chat.info.reasoning, isFalse);
      final speech = f.build({
        ...f.initial,
        "id": "tts",
        "kind": ModelRole.speech.name,
        "caps": "toolCall",
      });
      expect(speech.info.speaks, isTrue);
      expect(speech.info.toolCall, isFalse);
    });

    test("needs an id and numbers where numbers go", () {
      final f = form();
      expect(f.problem(f.initial), "");
      final named = {...f.initial, "id": "tuned-1"};
      expect(f.problem(named), isNull);
      expect(f.problem({...named, "context": "lots"}), "");
    });

    test("an edit replaces the model it started from", () {
      final f = form(model: const ModelInfo(id: "old", reasoning: true));
      expect(f.initial["caps"], contains("reasoning"));
      final draft = f.build({...f.initial, "id": "new"});
      expect(draft.replacing, ("p2", "old"));
      expect(draft.info.id, "new");
    });
  });
}
