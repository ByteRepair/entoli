import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/pages/chat_settings.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/providers.dart";

import "../../harness.dart";
import "page_driver.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<String> seed({bool pinned = false, String? project}) async {
    final chat = await app.repo.createChat(title: "chat", project: project);
    if (pinned) await app.repo.saveState(chat.state.copyWith(pinned: true));
    return chat.state.id;
  }

  Future<PageDriver<ChatSettingsAppPage>> open(String id) async {
    final page = PageDriver(app, ChatSettingsAppPage(id));
    await page.until(() => page.page.meta != null);
    return page;
  }

  Future<void> save(PageDriver<ChatSettingsAppPage> page) async {
    await page.tool("save").run();
    await page.until(() => !page.open);
  }

  test(
    "Thinking stands at the app's answer until the chat picks its own",
    () async {
      await app.container
          .read(appSettingsProvider.notifier)
          .setReasoningEffort(ReasoningEffort.low);
      final id = await seed();
      final page = await open(id);
      final thinking = page.at<ChoiceController<ReasoningEffort>>("thinking");
      expect(thinking.value, isNull);
      expect(thinking.inherited, ReasoningEffort.low);

      await thinking.set(ReasoningEffort.high);
      expect(
        page.at<ChoiceController<ReasoningEffort>>("thinking").value,
        ReasoningEffort.high,
      );
      await save(page);
      expect((await app.savedMeta(id)).reasoningEffort, ReasoningEffort.high);
    },
  );

  test("a chat's model is its own, Default naming what it inherits", () async {
    await app.seedGlobalDefault(providerId: "p", modelId: "global");
    final id = await seed();
    final page = await open(id);
    final model = page.at<ModelPickController>("model");
    expect(model.choice, (providerId: null, modelId: null));
    expect(model.inherited, (providerId: "p", modelId: "global"));

    await model.set((providerId: "p", modelId: "mine"));
    await save(page);
    final meta = await app.savedMeta(id);
    expect((meta.provider, meta.model), ("p", "mine"));

    final again = await open(id);
    await again.at<ModelPickController>("model").set((
      providerId: null,
      modelId: null,
    ));
    await save(again);
    expect((await app.savedMeta(id)).model, isNull);
  });

  test(
    "running commands is the LLMs page's own, at the chat's level",
    () async {
      final id = await seed();
      final page = await open(id);
      final mode = page.at<ChoiceController<ApproveMode>>("approveMode");
      expect(mode.value, isNull);
      expect(mode.unsettable, isTrue);

      await mode.set(ApproveMode.never);
      await save(page);
      expect((await app.savedMeta(id)).approveMode, ApproveMode.never);

      final again = await open(id);
      await again.at<ChoiceController<ApproveMode>>("approveMode").set(null);
      await save(again);
      expect((await app.savedMeta(id)).approveMode, isNull);
    },
  );

  test("keeping out of memory stores the off, and on stores nothing", () async {
    final id = await seed();
    final page = await open(id);
    expect(page.at<ToggleController>("memory").value, isTrue);

    await page.at<ToggleController>("memory").set(false);
    await save(page);
    expect((await app.savedMeta(id)).memoryOff, isTrue);

    final again = await open(id);
    await again.at<ToggleController>("memory").set(true);
    await save(again);
    expect((await app.savedMeta(id)).memoryOff, isNull);
  });

  test("a project that keeps no memories says so and takes nothing", () async {
    final id = await seed(project: "anonymous");
    final page = await open(id);
    final memory = page.at<ToggleController>("memory");
    expect(memory.enabled, isFalse);
    expect(memory.description, "This project keeps no memories.");
  });

  test("a chat can turn the sandbox off for itself", () async {
    final id = await seed();
    final page = await open(id);
    await page.at<ToggleController>("sandbox").set(false);
    await save(page);
    expect((await app.savedMeta(id)).sandbox, isFalse);
  });

  test("a pinned chat says so in place of how long it lives", () async {
    final pinned = await open(await seed(pinned: true));
    expect(pinned.find<ChoiceController>("ttl"), isNull);
    expect(pinned.find<NoticeController>("pinned"), isNotNull);

    final free = await open(await seed());
    final ttl = free.at<ChoiceController>("ttl");
    expect(ttl.inherited, isA<TempChatTtl>());
    expect(free.find<NoticeController>("pinned"), isNull);
  });

  test("leaving with a change asks first, and without one does not", () async {
    final page = await open(await seed());
    expect(page.page.leaving(page.reader), isNull);
    await page.at<ToggleController>("sandbox").set(false);
    expect(page.page.leaving(page.reader)?.confirmLabel, "Discard");
  });

  test("Delete takes the chat and every page over it away", () async {
    final id = await seed();
    final page = await open(id);
    final delete = page.at<ActionController>("delete");
    expect((await delete.confirm())?.destructive, isTrue);
    await delete.run();
    expect(page.open, isFalse);
    final chats = await app.repo.listChats();
    expect(chats.map((c) => c.id), isNot(contains(id)));
  });

  test("a new chat's settings hand back the draft on Save", () async {
    ChatMeta? saved;
    final page = PageDriver(
      app,
      NewChatSettingsAppPage(
        initial: ChatMeta(),
        project: null,
        onSave: (meta) => saved = meta,
      ),
    );
    await page.at<ToggleController>("sandbox").set(false);
    await page.tool("save").run();
    expect(saved?.sandbox, isFalse);
    expect(page.open, isFalse);
  });
}
