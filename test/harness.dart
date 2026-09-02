import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/builtin/llm/local_prefill.dart";
import "package:agent_chat/data/builtin/local_shell.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/data/local/file_byte_repair_store.dart";
import "package:agent_chat/data/sync/sync_hub.dart" show RemoteChatEntry, SyncHub;
import "package:agent_chat/domain/sync/devices.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:agent_chat/domain/sync/relay_signaling.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/chat_store.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/reminder.dart";
import "package:agent_chat/domain/shell.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/domain/voice.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/mirror_controller.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";
import "package:agent_chat/ui/focus_follows_keyboard.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/theme.dart";
import "package:agent_chat/ui/widgets/model_picker.dart";

import "fakes.dart";

/// The shell a test gets by default: a real host shell where the test pretends
/// to be Android — [proot] or [abi] set — and `UnavailableShell` otherwise,
/// which is the web default. The terminal settings page gates on
/// `canRunCommands`, so a test pretending to be Android has to answer true the
/// way the real one would. A test pretending to be a native desktop that the
/// two knobs cannot distinguish passes [shell] explicitly.
Shell _defaultShell(bool proot, String? abi) =>
    proot || abi != null
        ? LocalShell(environment: () => const {})
        : const UnavailableShell();

/// The app over a throwaway data directory, with the backend faked. Create one
/// per test and [dispose] it in `tearDown`.
class TestApp {
  TestApp._({
    required this.config,
    required this.backend,
    required this.picker,
    required this.launcher,
    required this.handoff,
    required this.assistant,
    required this.reminderAlarms,
    required this.backups,
    required this.restart,
    required this.store,
    required this.linkOpener,
    required this.voice,
    required this.voiceModels,
    required this.rootfs,
    required this.localModels,
    required this.localLlm,
    required this.prefill,
    required this.work,
    required this.container,
  });

  /// [store] defaults to the real one over a temp directory, since most of the
  /// suite is checking what the app does with what is on disk. Pass a
  /// [FakeChatStore] where the subject is which records a turn wrote.
  ///
  /// [handoff] is which of the three platforms the workspace explorer thinks it
  /// is on. The default can do nothing outside the app, which is right for
  /// every test that is not about the explorer.
  /// [voiceModels] is which voice models the app has downloaded. The default
  /// has none, which is what takes voice mode off the composer.
  ///
  /// [nativeVoice] is which of the device's own engines it has, the thing an
  /// Android phone answers and nothing else does. It joins [voiceModels] in the
  /// usable set the way `main` builds it, so a test says which engines exist
  /// rather than which sentinel ids to pretend are installed. The default has
  /// neither, which is every platform a VM test would otherwise be pretending
  /// to be.
  /// [localModels] is which on-device models are downloaded, and [localLlm] the
  /// server that would run one — the two halves the On-device page turns on. The
  /// default server is unavailable, which is every platform but Android and so
  /// what most of the suite should be pretending to be.
  /// [linuxes] is which distributions are installed, and [proot] whether this
  /// build could run one at all — the two halves the Terminal page turns on.
  /// The default is a build with no proot in it, which is every platform but
  /// Android and so what most of the suite should be pretending to be.
  /// [abi] is what the device answers with, and only Android answers at all —
  /// so it is named by a test that is about one, and left alone by the rest.
  /// [systemAccent] is the colour the system is themed to, which is the other
  /// thing only an Android answers: null is every platform without one, and so
  /// a settings page with no Material 3 Expressive switch on it.
  ///
  /// [hub] is for the one page that reads a [SyncHub] directly — the Sync
  /// settings category, which draws this device's identity and the paired
  /// list off it. Build one with [testSyncHub], which is asynchronous because
  /// an identity is a generated keypair. Everything else about sync goes
  /// through the provider overrides below and needs no hub at all.
  ///
  /// [remotes] is the Remotes section of the sidebar: chats mirrored from a
  /// paired device. Empty by default, which is every test with no sync in it —
  /// and load-bearing, because it is also what stands in for the [SyncHub]
  /// nothing here builds. [mirrors] is what one of those chats reads as, and
  /// [control] whether this device is driving one. [drivenBy] is the other
  /// direction: chats of this device a paired one is typing into.
  factory TestApp.create({
    PromptLibrary? library,
    bool launcherIcons = true,
    ChatStore? store,
    Shell? shell,
    FakeFileHandoff? handoff,
    FakeVoice? voice,
    FakeReminderAlarms? reminderAlarms,
    List<Reminder> reminders = const [],
    Set<String> voiceModels = const {},
    NativeVoiceEngines nativeVoice = NativeVoiceEngines.none,
    Set<String> linuxes = const {},
    bool proot = false,
    Set<String> localModels = const {},
    FakeLocalLlm? localLlm,
    bool prefill = false,
    String? abi,
    int? systemAccent,
    List<RemoteChatEntry> remotes = const [],
    Map<String, ChatViewState> mirrors = const {},
    Map<String, String> drivenBy = const {},
    MirrorControl control = const MirrorControl(),
    SyncHub? hub,
  }) {
    final config = tempConfig();
    final backend = FakeBackend();
    final picker = FakeAttachmentPicker();
    final launcher = FakeLauncherIcons(available: launcherIcons);
    final files = handoff ?? FakeFileHandoff();
    final assist = FakeAssistantLaunch();
    final alarms = reminderAlarms ?? FakeReminderAlarms(available: false);
    final backups = FakeBackupHandoff();
    final restart = FakeAppRestart();
    final chats = store ?? FileChatStore(config);
    final linkOpener = FakeLinkOpener();
    final speech = voice ?? FakeVoice();
    final models = FakeVoiceModelStore(installed: voiceModels);
    final linux = FakeRootfsStore(installed: linuxes);
    final onDevice = FakeLocalModelStore(installed: localModels);
    final server = localLlm ?? FakeLocalLlm(available: false);
    final work = FakeBackgroundWork();
    // The real one over the two fakes it sits between: what a page shows of a
    // warm-up, and what stopping one reaches, is all its own.
    final warmUp = prefill
        ? LocalPrefill(llm: server, background: work, warmup: testWarmup())
        : null;
    final system = {
      if (nativeVoice.recognition) nativeRecognition.id,
      if (nativeVoice.speech) nativeSpeech.id,
    };
    return TestApp._(
      config: config,
      backend: backend,
      picker: picker,
      launcher: launcher,
      handoff: files,
      assistant: assist,
      reminderAlarms: alarms,
      backups: backups,
      restart: restart,
      store: chats,
      linkOpener: linkOpener,
      voice: speech,
      voiceModels: models,
      rootfs: linux,
      localModels: onDevice,
      localLlm: server,
      prefill: warmUp,
      work: work,
      container: ProviderContainer(
        overrides: [
          chatStoreProvider.overrideWithValue(chats),
          agentBackendProvider.overrideWithValue(backend),
          shellProvider.overrideWithValue(
              shell ?? _defaultShell(proot, abi)),
          appConfigProvider.overrideWithValue(config),
          attachmentPickerProvider.overrideWithValue(picker),
          promptLibraryProvider.overrideWith2(
              (project) => PromptLibraryNotifier(project, library ?? testLibrary())),
          launcherIconsProvider.overrideWithValue(launcher),
          systemAccentProvider.overrideWithValue(systemAccent),
          fileHandoffProvider.overrideWithValue(files),
          assistantLaunchProvider.overrideWithValue(assist),
          reminderAlarmsProvider.overrideWithValue(alarms),
          remindersProvider.overrideWith(() => Reminders(reminders)),
          reminderTurnDriverProvider.overrideWithValue(FakeReminderTurnDriver()),
          backupHandoffProvider.overrideWithValue(backups),
          appRestartProvider.overrideWithValue(restart),
          linkOpenerProvider.overrideWithValue(linkOpener),
          voiceProvider.overrideWithValue(speech),
          voiceModelStoreProvider.overrideWithValue(models),
          // Seeded the way the app seeds it, before the first frame: see
          // [InstalledVoiceModels].
          installedVoiceModelsProvider.overrideWith(
              () => InstalledVoiceModels({...voiceModels, ...system},
                  system: system)),
          rootfsStoreProvider.overrideWithValue(linux),
          byteRepairStoreProvider.overrideWithValue(FileByteRepairStore(
              config: config,
              project: ByteRepairProject().dir,
              workspace: config.projectWorkspaceDir(project: ByteRepairProject().dir),
              rootfsStore: linux)),
          installedRootfsProvider.overrideWith(() => InstalledRootfs(linuxes)),
          localModelStoreProvider.overrideWithValue(onDevice),
          localLlmProvider.overrideWithValue(server),
          localPrefillProvider.overrideWithValue(warmUp),
          installedLocalModelsProvider
              .overrideWith(() => InstalledLocalModels(localModels)),
          // A build with proot staged into it is an Android one, so [proot]
          // answers for the ABI where a test did not bother to.
          deviceAbiProvider.overrideWithValue(abi ?? (proot ? "arm64-v8a" : null)),
          prootAvailableProvider.overrideWithValue(proot),
          appVersionProvider.overrideWithValue(testAppVersion),
          backgroundWorkProvider.overrideWithValue(work),
          if (hub != null) syncHubProvider.overrideWithValue(hub),
          remoteChatsProvider.overrideWith(() => FakeRemoteChats(remotes)),
          drivenChatsProvider.overrideWith(() => FakeDrivenChats(drivenBy)),
          mirrorChatControllerProvider
              .overrideWith2((id) => FakeMirrorChat(id, mirrors)),
          mirrorControlProvider
              .overrideWith2((id) => FakeMirrorControl(id, control)),
        ],
      ),
    );
  }

  final AppConfig config;
  final FakeBackend backend;
  final FakeAttachmentPicker picker;
  final FakeLauncherIcons launcher;
  final FakeFileHandoff handoff;
  final FakeAssistantLaunch assistant;

  /// The clock a reminder is set against. Default unavailable, which is every
  /// platform but Android and so what most of the suite should be pretending
  /// to be.
  final FakeReminderAlarms reminderAlarms;
  final FakeBackupHandoff backups;
  final FakeAppRestart restart;
  final ChatStore store;
  final FakeLinkOpener linkOpener;
  final FakeVoice voice;
  final FakeVoiceModelStore voiceModels;
  final FakeRootfsStore rootfs;
  final FakeLocalModelStore localModels;
  final FakeLocalLlm localLlm;

  /// The warm-up, where a test asked for one — null otherwise, which is the
  /// platform most of the suite is pretending to be.
  final LocalPrefill? prefill;

  final FakeBackgroundWork work;
  final ProviderContainer container;

  ChatRepository get repo => container.read(chatRepositoryProvider);

  /// Settings on disk, written the way the app writes them — which is also
  /// what puts them in the synchronous copy `AppSettings.load` reads.
  Future<void> seedSettings(AppSettings settings) => settings.save(config);

  /// The app-level default, written the way the app writes it.
  Future<void> seedGlobalDefault({String? providerId, String? modelId}) =>
      seedSettings(AppSettings(defaultProviderId: providerId, defaultModelId: modelId));

  /// Pick both of [voiceModelPair], which is what makes voice mode ready. From
  /// a `testWidgets` body this wants a real clock: `io(tester, app.pickVoiceModels)`.
  Future<void> pickVoiceModels() async {
    final settings = container.read(appSettingsProvider.notifier);
    await settings.setVoiceRecognitionModel(voiceModelPair.recognition);
    await settings.setVoiceSpeechModel(voiceModelPair.speech);
  }

  /// A chat that is already in the sidebar, which creating one now is.
  Future<Chat> seedChat({String title = "old chat", String? project}) =>
      repo.createChat(title: title, project: project);

  /// A chat open to be taken away from. Nothing selected is the new-chat
  /// screen, so a test about arriving there has to start somewhere else for
  /// the arrival to be visible at all.
  Future<Chat> openSomeChat({String title = "old chat"}) async {
    final chat = await seedChat(title: title);
    container.read(selectedChatIdProvider.notifier).select(chat.state.id);
    return chat;
  }

  /// A whole chat on disk, conversation and all.
  Future<void> writeChat(Chat chat, {bool finished = true}) =>
      writeChatVia(repo, chat, finished: finished);

  /// A chat's own overrides, written the way the chat settings page writes them.
  Future<void> seedChatMeta(String chatId, ChatMeta meta) =>
      container.read(chatStoreProvider).saveMeta(chatId, meta);

  /// A seeded chat made temporary at the chat level. `reanchor` is the
  /// load-bearing half: without it the TTL has nothing to count from and the
  /// chat is silently not temporary, which every assertion about one then
  /// passes for the wrong reason.
  Future<void> makeTemporary(ChatState state,
          {TempChatTtl ttl = TempChatTtl.hours24}) async {
    await seedChatMeta(state.id, ChatMeta(tempChatTtl: ttl));
    await repo.saveState(state, reanchor: true);
  }

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
  void dispose() {
    prefill?.dispose();
    container.dispose();
  }
}

/// A real [SyncHub] with nothing under it: an in-memory registry and secret
/// store, and no signaling, so it binds no socket and dials nothing. What the
/// Sync page reads off one — the fingerprint, the peers, the pairing window —
/// is all its own, so faking the hub would only ever prove the fake.
Future<SyncHub> testSyncHub({
  DeviceRegistry? devices,
  AppSettings Function()? settings,
  String? hostname,
  RelayDial? relayDial,
}) async =>
    SyncHub(
      identity: await SyncIdentity.load(FakeSecretStore()),
      registry: devices ?? FakeDeviceRegistry(),
      settings: settings ?? AppSettings.new,
      lanSignaling: () => null,
      hostname: hostname,
      // Nothing to dial by default, so a test that forgets one fails rather
      // than reaching the network from whatever URL it configured.
      relayDial: relayDial ?? FakeRelaySignaling().dial,
    );

/// Put a whole chat on disk the way the app would have: its state, then its
/// conversation as the records a turn would have appended. There is no
/// whole-log write to call instead — see `ChatStore.append`.
Future<void> writeChatTo(ChatStore store, Chat chat, {bool finished = true}) async {
  await store.saveState(chat.state);
  await store.append(chat.state.id, _asWritten(chat.messages, finished));
}

/// The same through a [ChatRepository], which is what a UI or repository test
/// wants: `saveState` resolves the TTL and anchors it, so a chat written
/// straight to the store is one no turn could have produced.
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

/// Type [text] into the composer and send it, then wait for the bubble.
///
/// Two things here are not obvious and were re-derived at every call site
/// before this was shared. The bare `pump` is required: the send button builds
/// off a `ValueNotifier` and is dead until the frame after the field has
/// something in it. And the wait is for the bubble rather than for [text],
/// which is still in the field this pump is clearing — and rather than
/// `settleIo`, which would find an idle tree and stop while the chat was being
/// written, there being no spinner up until a turn starts.
Future<void> sendMessage(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.send));
  await pumpUntil(tester, find.byType(MessageBubble));
  await settleIo(tester);
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

/// The two models a ready voice session needs: what the voice tests install
/// through `TestApp.create(voiceModels: ...)` and pick through
/// [TestApp.pickVoiceModels]. One pair rather than a copy per test, and named
/// halves rather than a set, because a copy that installs one id and picks
/// another leaves voice mode reading "not ready" — and every assertion under
/// it then takes the settings branch instead of failing.
const voiceModelPair = (recognition: "whisper-tiny", speech: "piper-en_US-amy");
/// The same pair as a set, which is the shape `TestApp.create` installs.
final voiceModelIds = {voiceModelPair.recognition, voiceModelPair.speech};

/// What About reads. Nothing serves `version.json` under `flutter test`, so a
/// test that asserts on the version asserts on this — see `appVersion` in
/// `core/platform/`.
const testAppVersion = "1.2.3";

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
  final tile = find.widgetWithText(ListTile, category.label);
  // Only when it is off the bottom: [scrollTo] aligns what it reveals with the
  // top of the list, which would push the categories above it out of the tree
  // and leave the next call with nothing to tap.
  if (tile.evaluate().isEmpty) await scrollTo(tester, tile);
  await tester.tap(tile);
  await settleIo(tester);
}

/// Open the model dropdown. Scoped to [ModelPicker]: the optional pickers on
/// the same page are dropdowns of the same type.
Future<void> openDropdown(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(ModelPicker),
    matching: find.byType(DropdownButtonFormField<ModelOption?>),
  ));
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

/// Give whatever is still in flight a chance to land. The predicate may be
/// async, since some of what lands has to be read back off disk.
///
/// The ceiling is generous because it costs nothing: this returns the moment
/// the condition holds, so only a genuine failure ever pays it. At 200ms the
/// title call was occasionally still in flight on a machine running the rest
/// of the suite alongside it, which is what CI always is.
///
/// For `test`, not `testWidgets`: it waits on the real clock, which a widget
/// test's fake one only advances when the tree is pumped.
Future<void> waitFor(FutureOr<bool> Function() done,
    {String what = "it", Duration limit = const Duration(seconds: 2)}) async {
  final end = DateTime.now().add(limit);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) fail("$what never happened");
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// A data directory that cleans itself up when the test ends. `forDirectory`
/// deliberately creates nothing, and every caller needs the default project's
/// directories — made with `dart:io` so this stays synchronous.
AppConfig tempConfig([String prefix = "agent_chat_test_"]) {
  final tmp = Directory.systemTemp.createTempSync(prefix);
  final config = AppConfig.forDirectory(tmp.path, fileSystemIo);
  Directory(config.chatsDir()).createSync(recursive: true);
  Directory(config.projectWorkspaceDir()).createSync(recursive: true);
  addTearDown(() {
    if (!tmp.existsSync()) return;
    // The read-only guard leaves the skills directories `555`; a deletion
    // needs the parent writable, so give it back before tearing down.
    if (Platform.isLinux || Platform.isAndroid) {
      try {
        Process.runSync("chmod", ["-R", "u+w", tmp.path]);
      } catch (_) {}
    }
    tmp.deleteSync(recursive: true);
  });
  return config;
}
