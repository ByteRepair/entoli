import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/chat_settings_draft.dart";
import "package:agent_chat/app/settings/scope.dart";
import "package:agent_chat/app/reader.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/settings/keys.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/providers.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart"
    show ProviderListenable, ProviderOrFamily;

import "../harness.dart";

/// The container as a reader, outside any build: [watch] only reads.
final class ContainerReader implements SettingReader {
  const ContainerReader(this.container);

  final ProviderContainer container;

  @override
  T watch<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  void invalidate(ProviderOrFamily provider) => container.invalidate(provider);
}

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  ChatSettingsEditor editor() => app.container.read(chatSettingsEditorProvider);

  Future<ChatSettingsDraft> open({String? project}) async {
    final chat = await app.repo.createChat(title: "chat", project: project);
    return editor().load(chat.state.id);
  }

  SettingsScope scope(ChatSettingsDraft draft) =>
      scopeAt(ContainerReader(app.container), draft.at);

  test("thinking stands at the app's answer until the chat picks", () async {
    await app.container
        .read(appSettingsProvider.notifier)
        .setReasoningEffort(ReasoningEffort.low);
    final draft = await open();
    expect(scope(draft).own(SettingKeys.reasoningEffort), isNull);
    expect(
      scope(draft).inherited(SettingKeys.reasoningEffort),
      ReasoningEffort.low,
    );

    await scope(draft).write(SettingKeys.reasoningEffort, ReasoningEffort.high);
    await editor().save(draft);
    expect(
      (await app.savedMeta(draft.chatId!)).reasoningEffort,
      ReasoningEffort.high,
    );
  });

  test("a chat's model is its own pair, written in one change", () async {
    final draft = await open();
    await scope(
      draft,
    ).writeAll({SettingKeys.provider: "p", SettingKeys.model: "mine"});
    await editor().save(draft);
    final meta = await app.savedMeta(draft.chatId!);
    expect((meta.provider, meta.model), ("p", "mine"));

    final again = await editor().load(draft.chatId!);
    await scope(
      again,
    ).writeAll({SettingKeys.provider: null, SettingKeys.model: null});
    await editor().save(again);
    expect((await app.savedMeta(draft.chatId!)).model, isNull);
  });

  test("running commands inherits the app's until the chat sets it", () async {
    final draft = await open();
    expect(scope(draft).own(SettingKeys.approveMode), isNull);
    expect(scope(draft).parent, isNotNull);

    await scope(draft).write(SettingKeys.approveMode, ApproveMode.never);
    await editor().save(draft);
    expect((await app.savedMeta(draft.chatId!)).approveMode, ApproveMode.never);
  });

  test("every change marks the draft edited, and Save clears it", () async {
    final draft = await open();
    var heard = 0;
    draft.addListener(() => heard++);
    expect(draft.edited, isFalse);

    await scope(draft).write(SettingKeys.sandbox, false);
    expect((draft.edited, heard), (true, 1));

    await editor().save(draft);
    expect(draft.edited, isFalse);
    expect((await app.savedMeta(draft.chatId!)).sandbox, isFalse);
  });

  test("Save anchors a temporary chat at once", () async {
    final draft = await open();
    await scope(draft).write(SettingKeys.tempChatTtl, TempChatTtl.hours24);
    await editor().save(draft);
    final state = (await app.repo.openChat(draft.chatId!)).state;
    expect(state.tempTtlExpiresAt, isNotNull);
  });

  test("a new chat's draft is a copy of what it was handed", () {
    final initial = ChatMeta();
    final draft = ChatSettingsDraft.newChat(initial);
    scopeAt(
      ContainerReader(app.container),
      draft.at,
    ).write(SettingKeys.sandbox, false);
    expect(draft.meta.sandbox, isFalse);
    expect(initial.sandbox, isNull);
  });

  test("a chat with no state to read loads, and is deleted", () async {
    final chat = await app.repo.createChat(title: "chat");
    final id = chat.state.id;
    File(app.config.stateFile(id)).deleteSync();

    final draft = await editor().load(id);
    expect(draft.state, isNull);
    await editor().delete(id);
    expect(Directory(app.config.chatDir(id)).existsSync(), isFalse);
  });
}
