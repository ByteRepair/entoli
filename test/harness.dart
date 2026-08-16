import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/widgets/provider_model_selector.dart";

import "fakes.dart";

/// The app over a throwaway data directory, with the backend faked. Create one
/// per test and [dispose] it in `tearDown`.
class TestApp {
  TestApp._(this.config, this.backend, this.picker, this.launcher, this.container);

  factory TestApp.create({
    PromptLibrary? library,
    bool launcherIcons = true,
  }) {
    final config = tempConfig();
    final backend = FakeBackend();
    final picker = FakeAttachmentPicker();
    final launcher = FakeLauncherIcons(available: launcherIcons);
    return TestApp._(
      config,
      backend,
      picker,
      launcher,
      ProviderContainer(
        overrides: [
          chatStoreProvider.overrideWithValue(FileChatStore(config)),
          agentBackendProvider.overrideWithValue(backend),
          appConfigProvider.overrideWithValue(config),
          attachmentPickerProvider.overrideWithValue(picker),
          promptLibraryProvider.overrideWithValue(library ?? testLibrary()),
          launcherIconsProvider.overrideWithValue(launcher),
        ],
      ),
    );
  }

  final AppConfig config;
  final FakeBackend backend;
  final FakeAttachmentPicker picker;
  final FakeLauncherIcons launcher;
  final ProviderContainer container;

  ChatRepository get repo => container.read(chatRepositoryProvider);

  /// Settings on disk, written the way the app writes them — which is also
  /// what puts them in the synchronous copy `AppSettings.load` reads.
  Future<void> seedSettings(AppSettings settings) => settings.save(config);

  /// The app-level default, written the way the app writes it.
  Future<void> seedGlobalDefault({String? providerId, String? modelId}) =>
      seedSettings(AppSettings(defaultProviderId: providerId, defaultModelId: modelId));

  /// A chat that is already in the sidebar. Creating one no longer puts it
  /// there: it is a draft until something is said in it.
  Future<Chat> seedChat({String title = "old chat", String? project}) async {
    final chat = await repo.createChat(title: title, project: project);
    await repo.save(chat);
    return chat;
  }

  /// A chat's own overrides, written the way the chat settings page writes them.
  Future<void> seedChatMeta(String chatId, ChatMeta meta) =>
      container.read(chatStoreProvider).saveMeta(chatId, meta);

  Future<ChatMeta> savedMeta(String chatId) =>
      container.read(chatStoreProvider).loadMeta(chatId);

  /// Pump [child] as the whole app. [settle] is for a widget that never comes
  /// to rest — a spinner runs forever, and settling on one times out.
  Future<void> pump(WidgetTester tester, Widget child, {bool settle = true}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: MaterialApp(home: child)),
    );
    if (settle) await settleIo(tester);
  }

  /// `tempConfig` already registers the directory's own teardown.
  void dispose() => container.dispose();
}

/// A chat's state as a store test hands it in, dated so [day] orders one
/// against another.
ChatState makeState(String id, {String? project, int day = 2}) => ChatState(
      id: id,
      title: "Test chat $id",
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, day),
      project: project,
    );

/// Settle, giving the app's own file I/O real time as it goes. Anything that
/// reads the store draws a spinner until it answers, and a spinner is a running
/// animation, so plain `pumpAndSettle` times out where it used to return. Loops
/// while anything is animating: a real round for the I/O, then a frame so the
/// animation itself advances.
/// [least] rounds happen whatever the tree looks like: a store write started by
/// a tap shows no spinner while it runs, so an empty frame is not evidence that
/// it landed.
Future<void> settleIo(WidgetTester tester, {int least = 6, int tries = 40}) async {
  for (var i = 0; i < tries && (i < least || tester.binding.transientCallbackCount > 0); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

/// Run [body] where its file I/O can actually complete. A `testWidgets` body
/// runs on a fake clock, and the store is asynchronous now — awaiting a save
/// directly in one waits forever. Everything that reads or writes through the
/// store or the settings goes through here.
Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
  // Drain first. The store runs one operation at a time, so a read here would
  // queue behind a save the turn left in flight — and that save only advances
  // when the tree is pumped, which cannot happen from inside `runAsync`.
  await settleIo(tester);
  return (await tester.runAsync(body)) as T;
}

/// Pump until [until] matches, letting real file I/O run in between. A widget
/// test's clock is fake and never advances it, so anything read off disk needs
/// real time and a rebuild interleaved by hand.
Future<void> pumpUntil(WidgetTester tester, Finder until, {int tries = 50}) async {
  for (var i = 0; i < tries && until.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
}

/// The app under system bars, the way Android draws it: the window is the whole
/// screen and what the status and navigation bars cover is [padding].
Widget underSystemBars(EdgeInsets padding, Widget child) => Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(padding: padding, viewPadding: padding),
        child: child,
      ),
    );

/// Bring [target] into view. A page taller than the test window builds only
/// the part of itself that shows, so the finders cannot see the rest.
Future<void> scrollTo(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.dragUntilVisible(target, find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pumpAndSettle();
  }
  // Built is not the same as tappable: the drag stops as soon as the target
  // exists, which can leave half of it under the edge of the window.
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// Open one of the two provider/model dropdowns. Scoped to the picker: other
/// inheritable fields on the same page are dropdowns of the same type.
Future<void> openDropdown(WidgetTester tester, {required bool model}) async {
  final dropdowns = find.descendant(
    of: find.byType(ProviderModelSelector),
    matching: find.byType(DropdownButtonFormField<String?>),
  );
  await tester.tap(model ? dropdowns.last : dropdowns.first);
  await tester.pumpAndSettle();
}

/// Item labels of the open dropdown popup, which renders in its own ListView
/// above the page's.
List<String?> popupLabels(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(
      of: find.byType(ListView).last,
      matching: find.byType(Text),
    ))
    .map((t) => t.data)
    .toList();

/// A data directory that cleans itself up when the test ends. `forDirectory`
/// deliberately creates nothing, and every caller needs the default project's
/// directories — made with `dart:io` so this stays synchronous.
AppConfig tempConfig([String prefix = "agent_chat_test_"]) {
  final tmp = Directory.systemTemp.createTempSync(prefix);
  final config = AppConfig.forDirectory(tmp.path, fileSystemIo);
  Directory(config.chatsDir()).createSync(recursive: true);
  Directory(config.projectWorkspaceDir()).createSync(recursive: true);
  addTearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });
  return config;
}
