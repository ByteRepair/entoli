import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/chat_store.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/focus_follows_keyboard.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/theme.dart";
import "package:agent_chat/ui/widgets/provider_model_selector.dart";

import "fakes.dart";

/// The app over a throwaway data directory, with the backend faked. Create one
/// per test and [dispose] it in `tearDown`.
class TestApp {
  TestApp._(this.config, this.backend, this.picker, this.launcher, this.handoff,
      this.backups, this.store, this.linkOpener, this.container);

  /// [store] defaults to the real one over a temp directory, since most of the
  /// suite is checking what the app does with what is on disk. Pass a
  /// [FakeChatStore] where the subject is which records a turn wrote.
  ///
  /// [handoff] is which of the three platforms the workspace explorer thinks it
  /// is on. The default can do nothing outside the app, which is right for
  /// every test that is not about the explorer.
  factory TestApp.create({
    PromptLibrary? library,
    bool launcherIcons = true,
    ChatStore? store,
    FakeFileHandoff? handoff,
  }) {
    final config = tempConfig();
    final backend = FakeBackend();
    final picker = FakeAttachmentPicker();
    final launcher = FakeLauncherIcons(available: launcherIcons);
    final files = handoff ?? FakeFileHandoff();
    final backups = FakeBackupHandoff();
    final chats = store ?? FileChatStore(config);
    final linkOpener = FakeLinkOpener();
    return TestApp._(
      config,
      backend,
      picker,
      launcher,
      files,
      backups,
      chats,
      linkOpener,
      ProviderContainer(
        overrides: [
          chatStoreProvider.overrideWithValue(chats),
          agentBackendProvider.overrideWithValue(backend),
          appConfigProvider.overrideWithValue(config),
          attachmentPickerProvider.overrideWithValue(picker),
          promptLibraryProvider.overrideWithValue(library ?? testLibrary()),
          launcherIconsProvider.overrideWithValue(launcher),
          fileHandoffProvider.overrideWithValue(files),
          backupHandoffProvider.overrideWithValue(backups),
          linkOpenerProvider.overrideWithValue(linkOpener),
        ],
      ),
    );
  }

  final AppConfig config;
  final FakeBackend backend;
  final FakeAttachmentPicker picker;
  final FakeLauncherIcons launcher;
  final FakeFileHandoff handoff;
  final FakeBackupHandoff backups;
  final ChatStore store;
  final FakeLinkOpener linkOpener;
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
    await repo.saveState(chat.state);
    return chat;
  }

  /// A whole chat on disk, conversation and all.
  Future<void> writeChat(Chat chat, {bool finished = true}) =>
      writeChatVia(repo, chat, finished: finished);

  /// A chat's own overrides, written the way the chat settings page writes them.
  Future<void> seedChatMeta(String chatId, ChatMeta meta) =>
      container.read(chatStoreProvider).saveMeta(chatId, meta);

  Future<ChatMeta> savedMeta(String chatId) =>
      container.read(chatStoreProvider).loadMeta(chatId);

  /// Pump [child] as the whole app. [settle] is for a widget that never comes
  /// to rest — a spinner runs forever, and settling on one times out.
  /// It wraps in `FocusFollowsKeyboard` because `main` does, and draws under the
  /// app's own palette because `main` does — a page that paints itself a colour
  /// of its own is only visible against the real one. [brightness] is for the
  /// widgets that pick a colour per palette rather than reading one out of the
  /// scheme.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    bool settle = true,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: entoliTheme(brightness),
          home: FocusFollowsKeyboard(child: child),
        ),
      ),
    );
    if (settle) await settleIo(tester);
  }

  /// `tempConfig` already registers the directory's own teardown.
  void dispose() => container.dispose();
}

/// Put a whole chat on disk the way the app would have: its state, then its
/// conversation as the records a turn would have appended. There is no
/// whole-log write to call instead — see `ChatStore.append`.
Future<void> writeChatTo(ChatStore store, Chat chat, {bool finished = true}) async {
  await store.saveState(chat.state);
  await store.append(chat.state.id, _asWritten(chat.messages, finished));
}

/// The same through a [ChatRepository], which is what a UI or repository test
/// wants: going straight to the store leaves the repository still holding the
/// chat as a draft, and everything it answers for one takes the draft path.
Future<void> writeChatVia(ChatRepository repo, Chat chat, {bool finished = true}) async {
  await repo.saveState(chat.state);
  await repo.append(chat.state.id, _asWritten(chat.messages, finished));
}

/// The records, plus the one closing each reply. A log with no closing record
/// reads as a turn the process was killed in the middle of, which is the point
/// of `finished: false` and a surprise everywhere else.
List<ChatRecord> _asWritten(List<Message> messages, bool finished) => [
      ...recordsOf(messages),
      if (finished)
        for (final m in messages.where((m) => m.role == MessageRole.assistant))
          ChatRecord.turnEnd(messageId: m.id, reason: TurnEnd.done),
    ];

/// A message as a store test hands it in.
Message makeMessage(String id, String text, {MessageRole role = MessageRole.user}) =>
    Message(
      id: id,
      role: role,
      createdAt: DateTime.utc(2026, 1, 1),
      parts: [MessagePart.text(text: text)],
    );

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

/// A chat parked mid-turn with [event] delivered and [until] on screen. The
/// turn is held open the way a real one is while the agent waits to be told
/// something, so the composer is gone and answering is the only way on.
/// Returns the chat's id.
///
/// Shared by everything that draws turn-scoped view state — approvals,
/// questions, and whatever asks next — since the ten lines that get a chat into
/// that position are the same ten every time.
Future<String> heldTurn(
  WidgetTester tester,
  TestApp app, {
  required AgentEvent event,
  required Finder until,
  String prompt = "get on with it",
  EdgeInsets bars = EdgeInsets.zero,
}) async {
  app.backend.scriptedEvents = [event];
  app.backend.hold = Completer<void>();
  addTearDown(() => app.backend.hold?.complete());

  final chat = await io(tester, () => app.repo.createChat());
  final id = chat.state.id;
  app.container.read(selectedChatIdProvider.notifier).select(id);
  await app.pump(tester, underSystemBars(bars, const ChatPage()), settle: false);
  await pumpUntil(tester, find.byType(Composer));
  await io(tester,
      () => app.container.read(chatControllerProvider(id).notifier).send(prompt));
  await pumpUntil(tester, until);
  return id;
}

/// Android's back key, as the engine reports it. True if something in the app
/// handled it; false is the app being left.
///
/// This asks the framework directly, which is a step further in than a real
/// press gets: Android only forwards one while the framework has said it wants
/// it. [frameworkHandlesBack] is that half, and a test that presses without
/// watching it passes happily over a device that closes the app.
Future<bool> pressBack(WidgetTester tester) async {
  final handled = await tester.binding.handlePopRoute();
  await settleIo(tester);
  return handled;
}

/// Every answer the framework has given the platform about who owns the back
/// key, newest last. Android keeps its own back callback disabled while the
/// latest is false, so the press finishes the activity instead of arriving.
///
/// Install it before the thing under test: this is what the app *said*, not
/// what it would have done if asked.
///
/// It resumes the app as well, because a test starts with no lifecycle state at
/// all and `WidgetsApp` deliberately says nothing to the engine until there is
/// one — so without this the list is empty however the app behaves. And it
/// takes `SystemChannels.platform` over for the test, which `Clipboard` and
/// `HapticFeedback` ride too.
List<bool> frameworkHandlesBack(WidgetTester tester) {
  final answers = <bool>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == "SystemNavigator.setFrameworkHandlesBack") {
      answers.add(call.arguments as bool);
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  messenger.handlePlatformMessage(
    "flutter/lifecycle",
    const StringCodec().encodeMessage(AppLifecycleState.resumed.toString()),
    (_) {},
  );
  return answers;
}

/// Everything the app put on the clipboard, in order. Takes
/// `SystemChannels.platform` over for the test, the same way
/// [frameworkHandlesBack] does — so a test wanting both wants one of them.
List<String> clipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == "Clipboard.setData") {
      copied.add((call.arguments as Map)["text"] as String);
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// The soft keyboard, the way the platform reports one: insets over the bottom
/// of the window, and nothing else. [up] false is it going away — which on
/// Android is the whole of what a back gesture says about it.
Future<void> softKeyboard(WidgetTester tester, {required bool up}) async {
  addTearDown(tester.view.resetViewInsets);
  tester.view.viewInsets = FakeViewPadding(bottom: up ? 300 : 0);
  await tester.pump();
}

/// Whether [button] would do anything if it were pressed. A dead one is still
/// drawn and still hit by a tap, so its callback is the only thing that says so.
///
/// `IconButton` is not a `ButtonStyleButton`, which is why this asks twice.
bool enabled(WidgetTester tester, Finder button) => switch (tester.widget(button)) {
      IconButton(:final onPressed) => onPressed != null,
      ButtonStyleButton(:final onPressed) => onPressed != null,
      final other => throw ArgumentError("not a button: ${other.runtimeType}"),
    };

/// An icon button by the tooltip on it, which is how most of them are named.
Finder buttonTipped(String tooltip) =>
    find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton));

/// Whether [field] holds the caret. A `TextField` here has no `FocusNode` of its
/// own, so the node to ask is the `EditableText`'s inside it — which is also
/// what a `SelectableText` is built out of.
bool holdsCaret(WidgetTester tester, Finder field) => tester
    .widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)))
    .focusNode
    .hasFocus;

/// Run the test in a window of [size], put back when it ends. Anything
/// asserting about a layout either side of a breakpoint needs one; forgetting
/// the reset leaks the size into a later test.
void useWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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

/// The settings page opened on [category]. A default would mean two different
/// pages depending on which test file is being read, so it is named at every
/// call site.
Future<void> pumpSettings(
  WidgetTester tester,
  TestApp app,
  SettingsCategory category,
) async {
  await app.pump(tester, const SettingsPage());
  await openCategory(tester, category);
}

/// The settings page at its Appearance section, which is in General and far
/// enough down a test window to need scrolling to. Shared by the two files that
/// test what is in it.
Future<void> pumpAppearance(WidgetTester tester, TestApp app) async {
  await pumpSettings(tester, app, SettingsCategory.general);
  await scrollTo(tester, find.text("Appearance"));
}

/// Move the settings page to [category]. Wide, the categories are a panel and
/// the tap only swaps what is beside it; narrow, they are the page and each
/// category is pushed over it — so getting to another one means going back to
/// the list first, which is what the bar's title says.
Future<void> openCategory(WidgetTester tester, SettingsCategory category) async {
  if (find.widgetWithText(AppBar, "Settings").evaluate().isEmpty) {
    await pressBack(tester);
  }
  await tester.tap(find.widgetWithText(ListTile, category.label));
  await settleIo(tester);
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
