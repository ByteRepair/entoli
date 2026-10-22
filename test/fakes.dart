import "dart:async";
import "dart:convert";

import "package:archive/archive.dart";
import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/local_pool_client.dart";
import "package:agent_chat/data/builtin/llm/local_prefill.dart";
import "package:agent_chat/data/sync/channel.dart";
import "package:agent_chat/data/sync/peers.dart" show PeerState;
import "package:agent_chat/data/sync/sync_hub.dart" show RemoteChatEntry, RemoteProject;
import "package:agent_chat/domain/app_icon.dart";
import "package:agent_chat/domain/app_update.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/app_restart.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/attachment_picker.dart";
import "package:agent_chat/domain/backup_handoff.dart";
import "package:agent_chat/domain/background_work.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_store.dart";
import "package:agent_chat/domain/assistant_launch.dart";
import "package:agent_chat/domain/file_handoff.dart";
import "package:agent_chat/domain/link_opener.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:agent_chat/domain/local_model_store.dart";
import "package:agent_chat/domain/model_registry.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/file_watches.dart";
import "package:agent_chat/domain/reminder_alarms.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:agent_chat/domain/trigger_runner.dart";
import "package:agent_chat/domain/voice.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:agent_chat/domain/download.dart";
import "package:agent_chat/domain/rootfs.dart";
import "package:agent_chat/domain/rootfs_store.dart";
import "package:agent_chat/domain/secret_store.dart";
import "package:agent_chat/domain/sync/devices.dart";
import "package:agent_chat/domain/sync/relay_signaling.dart";
import "package:agent_chat/domain/voice_model_store.dart";
import "package:agent_chat/domain/project.dart" show ProjectRef;
import "package:agent_chat/providers.dart"
    show DeviceProjects, PairedDevices, RemoteChats, RemoteProjectNotifier;
import "package:agent_chat/ui/chat/mirror_controller.dart";
import "package:uuid/uuid.dart";

/// A [LinkOpener] that records what it was asked to open, for UI tests that
/// assert on the call rather than on a browser opening.
class FakeLinkOpener implements LinkOpener {
  final List<Uri> opened = [];
  final List<({String chatId, String artifactId, String entryFile, String? title})> openedArtifacts = [];

  @override
  Future<void> open(BuildContext context, Uri url) async => opened.add(url);

  @override
  Future<void> openArtifact(
    BuildContext context,
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) async =>
      openedArtifacts.add((chatId: chatId, artifactId: artifactId, entryFile: entryFile, title: title));
}

/// The models [testProvider] is answered with, labelled the way the real
/// registry labels them: `<provider display name> · <model id>`, and
/// deliberately out of order so tests can assert the UI sorts them.
final testProviderModels = [
  for (final id in ["qwen-2.5", "claude-sonnet-4", "llama-3", "claude-haiku-3"])
    ModelOption(providerId: testProviderId, modelId: id, label: "Test · $id"),
];

/// [models] as the model catalog, as models.dev would list them: each one
/// able to answer turns, and fetched, so no page reads as offline.
void seedCatalog(List<ModelOption> models) =>
    ModelCatalog.notifier.value = ModelCatalog.parse(jsonEncode({
      ModelCatalog.fetchedKey: "2026-01-01T00:00:00.000",
      for (final provider in models.map((m) => m.providerId).toSet())
        provider: {
          "models": {
            for (final m in models.where((m) => m.providerId == provider))
              m.modelId: {"tool_call": true},
          },
        },
    }));

/// The provider the model-picker tests configure: one entry with both defaults
/// named, so the injected "Default" entry has something to point at.
const testProviderId = "test";
const testProvider = LlmProviderConfig(
  id: testProviderId,
  label: "Test",
  api: LlmApi.openai,
  baseUrl: "https://test.example/v1",
  defaultModelId: "glm-5.3-flash",
  defaultLightModelId: "nemotron-3-nano:30b",
);

/// A library whose skills include two names sharing a prefix, so tests can
/// assert the menu filters, and whose entries are deliberately out of order.
PromptLibrary testLibrary() => PromptLibrary([
      _doc(CompletionKind.skill, "review", "review changes"),
      _doc(CompletionKind.skill, "revert", "undo the last turn"),
      _doc(CompletionKind.skill, "init", "guided AGENTS.md setup"),
      _doc(CompletionKind.agent, "explore", "fast codebase search"),
      _doc(CompletionKind.agent, "build", "the default agent"),
    ]);

PromptDocument _doc(CompletionKind kind, String name, String description) =>
    PromptDocument.parse(kind, name, "---\ndescription: $description\n---\n\nDo $name.\n");

/// A real 1x1 PNG: the chip decodes what it is given, so a stand-in string of
/// bytes would fail the codec rather than render.
final onePixelPng = base64Decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==");

/// An attachment with recognisable bytes, so a test can follow the same file
/// from the composer to the backend and back off disk.
Attachment testAttachment(
  String filename, {
  String mimeType = "text/plain",
  List<int> bytes = const [104, 105],
}) =>
    Attachment(filename: filename, mimeType: mimeType, bytes: Uint8List.fromList(bytes));

/// The launcher, which a test has none of. Records what it was told so a test
/// can assert the home screen was asked to change, not just the settings file.
class FakeLauncherIcons implements LauncherIcons {
  FakeLauncherIcons({this.available = true});

  @override
  final bool available;

  final List<AppIcon> used = [];

  @override
  Future<void> use(AppIcon icon) async => used.add(icon);
}

/// The automatic update's platform half, as a test sees it: whether the
/// settings page draws its row. The harness default is the unavailable one,
/// which is every non-desktop answer.
class FakeAppUpdateHost implements AppUpdateHost {
  FakeAppUpdateHost({this.available = false});

  @override
  final bool available;

  @override
  Future<void> check({required String? version, required bool enabled}) async {}
}

/// The platform's hold on the process, which a test has none of. Records what
/// it was told of each kind, and [stop] is one of the notifications' Stop being
/// pressed.
class FakeBackgroundWork implements BackgroundWork {
  final List<int> told = [];
  final List<bool> listened = [];
  final List<DownloadNotice?> downloads = [];
  final List<String?> prefills = [];
  final List<SyncNotice?> synced = [];
  final _stops = StreamController<BackgroundJob>.broadcast();

  @override
  Future<void> running(int turns) async => told.add(turns);

  @override
  Future<void> listening(bool active) async => listened.add(active);

  @override
  Future<void> downloading(DownloadNotice? notice) async => downloads.add(notice);

  @override
  Future<void> prefilling(String? model) async => prefills.add(model);

  @override
  Future<void> syncing(SyncNotice? notice) async => synced.add(notice);

  @override
  Stream<BackgroundJob> get stopRequests => _stops.stream;

  void stop([BackgroundJob job = BackgroundJob.turns]) => _stops.add(job);
}

/// The prefill's [Warmup], with the settings a test cares about and defaults
/// for the rest. One spelling: the record has five option fields, and a rename
/// of any of them should not be a hunt through the suite.
Warmup Function() testWarmup({
  int kvCachePrompts = 0,
  List<LlmMessage> messages = const [
    LlmMessage(role: LlmRole.system, text: "system prompt body"),
    LlmMessage(role: LlmRole.user, text: "Hello"),
  ],
  List<LlmTool> tools = const [],
}) =>
    () => (
          options: poolOptions(AppSettings(localModelKvCachePrompts: kvCachePrompts)),
          messages: messages,
          tools: tools,
        );

/// A user message as the app would have logged one, for the tests that hand a
/// turn to an agent or a backend. `sendPrompt` and `BuiltinAgent.run` take the
/// message rather than its text, since what the model is shown of a turn is the
/// message plus what is recorded on it — see "The projection".
Message userMessage(
  String text, {
  DateTime? at,
  Map<String, String> documents = const {},
  List<MessagePart> files = const [],
}) =>
    Message(
      id: "u1",
      role: MessageRole.user,
      createdAt: at ?? DateTime(2026),
      parts: [...files, MessagePart.text(text: text)],
      documents: documents,
    );

/// Stands in for the platform's file chooser, which no test can drive.
class FakeAttachmentPicker implements AttachmentPicker {
  final List<AttachmentKind> picks = [];

  /// What the next pick returns. Empty is a cancelled dialog.
  List<Attachment> scripted = const [];

  @override
  Future<List<Attachment>> pick(AttachmentKind kind) async {
    picks.add(kind);
    return scripted;
  }
}

/// The app building itself again, which a test has no `AppRoot` to do. The work
/// handed to it still runs — that is a restore, and a fake that swallowed it
/// would leave every test asserting on a data directory nothing had touched.
class FakeAppRestart implements AppRestart {
  var restarts = 0;

  @override
  Future<void> restart({Future<void> Function()? whileStopped}) async {
    restarts++;
    await whileStopped?.call();
  }
}

/// The save dialog and the chooser a backup leaves and arrives through, neither
/// of which a test can answer. What was saved is kept so a test can read the
/// document back, which is the only witness there is that Export did anything.
class FakeBackupHandoff implements BackupHandoff {
  final List<({String name, Uint8List bytes})> saved = [];

  /// What the next pick answers. Null is a cancelled chooser.
  Uint8List? scripted;

  @override
  Future<void> save(String name, Uint8List bytes) async =>
      saved.add((name: name, bytes: bytes));

  @override
  Future<Uint8List?> pick() async => scripted;
}

/// The system's assistant gesture, as the app sees it. [pending] is a launch
/// Kotlin noticed before Dart was listening — the gesture that started the app
/// — and [launch] is one arriving while it is already up.
class FakeAssistantLaunch implements AssistantLaunch {
  FakeAssistantLaunch({this.hasGesture = true});

  /// A launch waiting to be claimed. Taken once, the way the real one is.
  bool pending = false;

  final _arrived = StreamController<void>.broadcast();

  @override
  Stream<void> get launched => _arrived.stream;

  /// False is where no gesture exists — an iOS — and the settings section
  /// hides; true, every existing test's default, is an Android.
  @override
  final bool hasGesture;

  @override
  Future<bool> take() async {
    final had = pending;
    pending = false;
    return had;
  }

  void launch() {
    pending = true;
    _arrived.add(null);
  }
}

/// The alarm port a trigger is set against, with the answers a test wants
/// to control. [fire] and [tap] are the two things Android does on its own:
/// an alarm going off, and a notification being tapped.
class FakeReminderAlarms implements ReminderAlarms {
  FakeReminderAlarms({this.available = true, this.schedulesOverride});

  @override
  final bool available;

  /// Set where a test wants the "fires with the app closed" answer rather
  /// than the default one [available] gives, which is Android's.
  final bool? schedulesOverride;

  @override
  bool get schedules => schedulesOverride ?? available;

  var exact = true;
  var notifications = true;

  /// Whether the platform would hold the process for a turn started now.
  var canHold = true;

  /// How many times the hold an alarm took has been released.
  var released = 0;

  final scheduled = <int, DateTime>{};
  final cancelled = <int>[];
  final posted =
      <({String title, String body, String? chatId, String channel})>[];

  List<String> pendingFired = [];
  String? pendingOpen;

  final _nudges = StreamController<void>.broadcast();
  final _opens = StreamController<String>.broadcast();

  /// An alarm firing: held like the real one is, then nudged.
  void fire(String id) {
    pendingFired = [...pendingFired, id];
    _nudges.add(null);
  }

  /// A completion notification tapped.
  void tap(String chatId) {
    pendingOpen = chatId;
    _opens.add(chatId);
  }

  @override
  Future<bool> exactAllowed() async => exact;

  @override
  Future<void> requestExact() async {
    exact = true;
  }

  @override
  Future<bool> notificationsAllowed() async => notifications;

  @override
  Future<void> requestNotifications() async {
    notifications = true;
  }

  @override
  Future<void> schedule(int requestCode, DateTime at,
      {String? calendar, String? label, String? chatId}) async {
    scheduled[requestCode] = at;
  }

  @override
  Future<void> cancel(int requestCode) async {
    cancelled.add(requestCode);
    scheduled.remove(requestCode);
  }

  /// Codes the fake says it still holds beyond what a diff wanted — the
  /// launchd jobs a previous launch left behind. Empty unless a test writes
  /// it, which is every platform's honest answer but macOS's to fill.
  List<int> staleHeld = [];

  @override
  Future<List<int>> staleCodes(Set<int> wanted) async =>
      [for (final code in staleHeld) if (!wanted.contains(code)) code];

  @override
  Future<bool> canHoldTurn() async => canHold;

  @override
  Future<void> doneFiring() async {
    released++;
  }

  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) async {
    posted.add((title: title, body: body, chatId: chatId, channel: channel));
  }

  @override
  Future<List<String>> takeFired() async {
    final taken = pendingFired;
    pendingFired = [];
    return taken;
  }

  @override
  Stream<void> get fired => _nudges.stream;

  @override
  Future<String?> takeOpenChat() async {
    final taken = pendingOpen;
    pendingOpen = null;
    return taken;
  }

  @override
  Stream<String> get openChat => _opens.stream;
}

/// What a workspace file can do outside the app, which no test can drive: no
/// viewer opens, no share sheet appears, no chooser is answered. The capability
/// flags are the point — the explorer draws a different toolbar on each of the
/// three platforms, and the named constructors are those three.
class FakeFileHandoff implements FileHandoff {
  FakeFileHandoff({this.canReveal = false, this.exportKind, this.canImport = false});

  /// A desktop: a file manager and a viewer, nothing else.
  factory FakeFileHandoff.desktop() => FakeFileHandoff(canReveal: true);

  /// Android: the share sheet both ways, and no chooser of its own.
  factory FakeFileHandoff.android() => FakeFileHandoff(exportKind: ExportKind.share);

  /// A browser: a download out, a file input in.
  factory FakeFileHandoff.web() =>
      FakeFileHandoff(exportKind: ExportKind.download, canImport: true);

  @override
  final bool canReveal;
  @override
  final ExportKind? exportKind;
  @override
  final bool canImport;

  final List<String> opened = [];
  final List<String> revealed = [];
  final List<List<String>> exported = [];

  /// Whether each import asked for folders.
  final List<bool> imports = [];

  /// What the next import answers. Empty is a cancelled chooser.
  List<IncomingFile> scriptedImport = const [];

  /// What another app has shared and nothing has claimed. Emptied by
  /// [takeShare], the way the real one is.
  List<IncomingFile> pendingShare = const [];

  final _arrived = StreamController<void>.broadcast();

  @override
  Stream<void> get shareArrived => _arrived.stream;

  /// A share arriving while the app is already up.
  void share(List<IncomingFile> files) {
    pendingShare = files;
    _arrived.add(null);
  }

  @override
  Future<void> open(String path) async => opened.add(path);

  @override
  Future<void> reveal(String dir) async => revealed.add(dir);

  @override
  Future<void> export(List<String> paths) async => exported.add(paths);

  @override
  Future<List<IncomingFile>> import({required bool folders}) async {
    imports.add(folders);
    return scriptedImport;
  }

  @override
  Future<List<IncomingFile>> takeShare() async {
    final files = pendingShare;
    pendingShare = const [];
    return files;
  }
}

/// A file arriving from outside, with recognisable bytes so a test can follow
/// the same one from a chooser or a share into a workspace.
IncomingBytes incomingFile(String path, [String text = "hi"]) =>
    IncomingBytes(path, Uint8List.fromList(text.codeUnits));

class FakeBackend implements AgentBackend {
  var _created = 0;

  /// Which chats have a turn running. Driven by hand — a scripted turn is over
  /// the moment its events are yielded — so a test of the foreground service
  /// sets it and watches what follows.
  @override
  final ValueNotifier<Set<String>> runningTurns = ValueNotifier(const {});

  /// The memory notes a test wants the page to see: a real holder, so a test
  /// adds one the way the backend would.
  final MemoryNotes memoryNoteHolder = MemoryNotes();

  @override
  Stream<MemoryNote> get memoryNotes => memoryNoteHolder.notes;

  /// A real feed, so a test writes a sub-agent's records the way the backend
  /// would.
  @override
  final SubAgentFeed subAgents = SubAgentFeed();

  @override
  Future<Chat> createChat({String? title}) async {
    final now = DateTime.now();
    return Chat(
      state: ChatState(
        id: "fake-${++_created}",
        title: title ?? "New chat",
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  final List<({String prompt, String? model, String? provider})> questions = [];

  /// What `ask` answers. Null is a model that could not answer.
  String? scriptedAnswer;

  @override
  Future<String?> ask(String prompt,
      {required String? model, required String? provider}) async {
    questions.add((prompt: prompt, model: model, provider: provider));
    return scriptedAnswer;
  }

  /// The message itself rather than fields taken off it: what the model is
  /// shown of a turn is the whole message, so a test that wants the text, the
  /// date or what a `/skill` meant asks the message for it.
  final List<({Message prompt, List<Message> history, TurnSettings settings})>
      prompts = [];

  /// What the next turn streams back. Defaults to an immediate, empty reply.
  List<AgentEvent> scriptedEvents = const [DoneEvent()];

  /// What each of the next turns streams back, one entry per call: a retry
  /// round takes a different reply from the send that started it, and this is
  /// how a test scripts the whole sequence. [scriptedEvents] is still read
  /// first, so a test setting either gets what it set.
  List<List<AgentEvent>> scriptedRounds = const [];

  List<AgentEvent> _next() => scriptedRounds.isEmpty
      ? scriptedEvents
      : scriptedRounds.removeAt(0);

  /// When set, the turn stays open after the scripted events, the way a real
  /// one does while the backend is still working.
  Completer<void>? hold;

  @override
  Stream<AgentEvent> sendPrompt(String chatId, Message prompt,
      {List<Message> history = const [],
      List<ConversationCompaction> compactions = const [],
      TurnSettings settings = const TurnSettings(),
      SteerInbox? steers}) async* {
    prompts.add((prompt: prompt, history: history, settings: settings));
    this.steers = steers;
    yield* Stream.fromIterable(_next());
    yield* _held();
  }

  /// The same for `resumeTurn`, minus the prompt it does not have.
  final List<({List<Message> history, TurnSettings settings})> resumes = [];

  @override
  Stream<AgentEvent> resumeTurn(String chatId,
      {List<Message> history = const [],
      List<ConversationCompaction> compactions = const [],
      TurnSettings settings = const TurnSettings(),
      SteerInbox? steers}) async* {
    resumes.add((history: history, settings: settings));
    this.steers = steers;
    yield* Stream.fromIterable(_next());
    yield* _held();
  }

  /// The inbox of the turn opened last: what the user has said to it.
  SteerInbox? steers;

  final StreamController<AgentEvent> _pushed =
      StreamController<AgentEvent>.broadcast();

  /// Read what was said to the running turn, the way the agent does between
  /// steps. Reaches a turn held open by [hold].
  void deliverSteers() {
    for (final said in steers?.take() ?? const <Message>[]) {
      _pushed.add(SteerEvent(said));
    }
  }

  /// While [hold] is set, the turn stays open and streams what is pushed.
  Stream<AgentEvent> _held() {
    final held = hold;
    if (held == null) return const Stream.empty();
    final out = StreamController<AgentEvent>();
    final sub = _pushed.stream.listen(out.add);
    held.future.whenComplete(() async {
      await sub.cancel();
      await out.close();
    });
    return out.stream;
  }

  final List<List<Message>> resets = [];

  @override
  Future<void> resetSession(String chatId,
      {List<Message> history = const [],
      List<ConversationCompaction> compactions = const []}) async {
    resets.add(history);
  }

  /// What `compact` answers. Null is a summarizer that said nothing; set a
  /// record for a scripted summary, whose `upToMessageId` is the history's
  /// last message.
  String? scriptedSummary;

  final List<({String? instructions, int historyLength})> compactionCalls = [];

  @override
  Future<ConversationCompaction?> compact(String chatId,
      {required List<Message> history,
      required List<ConversationCompaction> compactions,
      required TurnSettings settings,
      required String? instructions}) async {
    compactionCalls
        .add((instructions: instructions, historyLength: history.length));
    if (scriptedSummary == null) return null;
    return ConversationCompaction(
        upToMessageId: history.lastOrNull?.id ?? "", summary: scriptedSummary!);
  }

  @override
  int? usageFor(String chatId) => usageHolder[chatId];

  /// What `usageFor` answers, keyed by chat id, in context tokens.
  final Map<String, int> usageHolder = {};

  @override
  int? contextWindowFor(String chatId) => null;

  @override
  Future<void> shutdown() async {}

  final List<String> aborted = [];

  @override
  Future<void> abort(String chatId) async {
    aborted.add(chatId);
    runningTurns.value = runningTurns.value.difference({chatId});
  }

  final List<({String approvalId, ApprovalResponse response})> approvals = [];

  @override
  Future<void> respondApproval(
      String chatId, String approvalId, ApprovalResponse response) async {
    approvals.add((approvalId: approvalId, response: response));
  }

  final List<({String requestId, List<String?> answers})> answered = [];

  @override
  Future<void> respondQuestions(
      String chatId, String requestId, List<String?> answers) async {
    answered.add((requestId: requestId, answers: answers));
  }

  final List<String> disposed = [];

  /// The shells [closeChatShell] ended, as the chat and the project it left.
  final List<(String, String?)> closedShells = [];

  @override
  Future<void> disposeChat(String chatId) async => disposed.add(chatId);

  @override
  void closeChatShell(String chatId, {required String? project}) =>
      closedShells.add((chatId, project));

  /// Two providers, two models each, deliberately not in alphabetical order so
  /// tests can assert the UI sorts them.
  List<ModelOption> modelList = const [
    ModelOption(providerId: "ollama-cloud", modelId: "llama-3", label: "Llama 3"),
    ModelOption(providerId: "ollama-cloud", modelId: "qwen-2.5", label: "Qwen 2.5"),
    ModelOption(providerId: "anthropic", modelId: "claude-sonnet-4", label: "Claude Sonnet 4"),
    ModelOption(providerId: "anthropic", modelId: "claude-haiku-3", label: "Claude Haiku 3"),
  ];

  @override
  Future<List<ModelOption>> models() async => modelList;
}

/// A `ChatStore` that keeps everything in memory, for the tests whose subject
/// is *what* gets written rather than where it lands. `FileChatStore` over a
/// temp directory is still what the store's own tests use — the layout on a
/// disk is the thing under test there — but a test asking which records a turn
/// produced does not need a filesystem, and polling one for them is how those
/// tests turn flaky.
class FakeChatStore implements ChatStore {
  final Map<String, ChatState> _states = {};
  final Map<String, List<ChatRecord>> _logs = {};
  final Map<String, ChatMeta> _metas = {};
  final Map<String, Map<String, Uint8List>> _resources = {};
  /// artifactId → relativePath → bytes, per chat.
  final Map<String, Map<String, Map<String, Uint8List>>> _artifacts = {};
  /// installId → package bytes, per chat.
  final Map<String, Map<String, Uint8List>> _skillInstalls = {};
  final Set<String> _projects = {};

  /// The chat's log, as it has been appended to. What the log tests assert on.
  List<ChatRecord> records(String chatId) => List.unmodifiable(_logs[chatId] ?? const []);

  @override
  Future<void> append(String chatId, List<ChatRecord> records) async =>
      _logs.putIfAbsent(chatId, () => []).addAll(records);

  @override
  Future<void> saveState(ChatState state) async => _states[state.id] = state;

  @override
  Future<void> retitle(String chatId, String title) async {
    final state = _states[chatId];
    if (state != null) _states[chatId] = state.copyWith(title: title);
  }

  @override
  Future<Chat> load(String id) async {
    final state = _states[id];
    if (state == null) throw StateError("no chat $id");
    return chatFrom(state, records(id));
  }

  @override
  Future<ChatState?> loadState(String id) async => _states[id];

  @override
  Future<List<ChatRecord>> readRecords(String chatId) async => records(chatId);

  final Map<String, List<ChatRecord>> _subAgents = {};

  /// A finished sub-agent's transcript, as [readSubAgentRecords] answers it.
  void stageSubAgent(String chatId, String callId, List<ChatRecord> records) =>
      _subAgents["$chatId/$callId"] = records;

  @override
  Future<List<ChatRecord>> readSubAgentRecords(String chatId, String callId) async =>
      _subAgents["$chatId/$callId"] ?? const [];

  @override
  Future<List<ChatState>> list() async =>
      _states.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<List<String>> listProjects() async => _projects.toList()..sort();

  @override
  Future<String?> projectOf(String chatId) async => _states[chatId]?.project;

  @override
  Future<void> createProject(String name) async => _projects.add(name);

  @override
  Future<void> deleteProject(String name) async {
    _projects.remove(name);
    for (final id in _states.entries.where((e) => e.value.project == name).map((e) => e.key).toList()) {
      await delete(id);
    }
  }

  @override
  Future<void> moveChat(String chatId, String? project) async {
    final state = _states[chatId];
    if (state != null) _states[chatId] = state.copyWith(project: project);
  }

  @override
  Future<void> delete(String id) async {
    _states.remove(id);
    _logs.remove(id);
    _metas.remove(id);
    _resources.remove(id);
    _artifacts.remove(id);
  }

  @override
  Future<String> saveResource(String chatId, String filename, Uint8List bytes) async {
    final resource = resourceName(filename);
    _resources.putIfAbsent(chatId, () => {})[resource] = bytes;
    return resource;
  }

  @override
  Future<Uint8List?> readResource(String chatId, String resource) async =>
      _resources[chatId]?[resource];

  @override
  Future<String> createArtifact(
      String chatId, String sourceDir, String entryFile,
      {String? project}) async {
    final artifactId = const Uuid().v4();
    _artifacts.putIfAbsent(chatId, () => {})[artifactId] = {
      entryFile: Uint8List.fromList(utf8.encode("<p>")),
    };
    return artifactId;
  }

  @override
  Future<void> updateArtifact(String chatId, String artifactId,
      String sourceDir, String entryFile,
      {String? project}) async {
    // Record that an update happened; the fake doesn't actually copy.
    _artifacts.putIfAbsent(chatId, () => {}).putIfAbsent(artifactId, () => {});
  }

  @override
  Future<Uint8List?> readArtifactFile(
    String chatId, String artifactId, String relativePath, {String? project}) async =>
      _artifacts[chatId]?[artifactId]?[relativePath];

  final Map<String, String> _plans = {};

  /// A chat's `PLAN.md`, as [readPlan] answers it.
  void stagePlan(String chatId, String plan) => _plans[chatId] = plan;

  @override
  Future<String?> readPlan(String chatId) async => _plans[chatId];

  @override
  Future<Uint8List?> readArtifactZip(String chatId, String artifactId,
      {String? project}) async {
    final files = _artifacts[chatId]?[artifactId];
    if (files == null || files.isEmpty) return null;
    final archive = Archive();
    for (final MapEntry(key: name, value: bytes) in files.entries) {
      archive.add(ArchiveFile.bytes(name, bytes));
    }
    return ZipEncoder().encodeBytes(archive, autoClose: true);
  }

  /// Puts files into a staged artifact, the way the backend's publish does —
  /// what a sync test wants on the far side of the wire is the content the
  /// artifact holds, and `createArtifact` copies a source directory a test
  /// building a wire case has no reason to make.
  void stageArtifact(
          String chatId, String artifactId, Map<String, List<int>> files) =>
      _artifacts.putIfAbsent(chatId, () => {})[artifactId] = {
        for (final MapEntry(key: name, value: bytes) in files.entries)
          name: Uint8List.fromList(bytes),
      };

  @override
  Future<String> artifactPath(String chatId, String artifactId, {String? project}) async =>
      "/tmp/test/$chatId/artifacts/$artifactId";

  @override
  Future<Uint8List?> readSkillInstall(String chatId, String installId) async =>
      _skillInstalls[chatId]?[installId];

  /// Stages a skill package under the fake, the way the backend would.
  void stageSkillInstall(String chatId, String installId, Uint8List bytes) =>
      _skillInstalls.putIfAbsent(chatId, () => {})[installId] = bytes;

  @override
  Future<ChatMeta> loadMeta(String chatId) async => _metas[chatId] ?? ChatMeta();

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async => _metas[chatId] = meta;
}

/// Listening and speaking, with neither. [hear] is the user saying something
/// and [spoken] is what the reply came out as, which is the pair every voice
/// test is written against.
class FakeVoice extends Voice {
  FakeVoice({
    this.available = true,
    this.hasEngineInstalls = true,
    this.hasModelCatalog = true,
  });

  @override
  final bool available;

  /// False is a browser: no engine installs to offer, so no missing-engine
  /// block. True is Android, the one platform the block is drawn for.
  @override
  final bool hasEngineInstalls;

  /// False is an iPhone: the engines are the whole of what can listen and
  /// speak, so the settings page draws neither list.
  @override
  final bool hasModelCatalog;

  /// The native picks the usable set is seeded with. Android's, unless a
  /// test makes this fake an iPhone's.
  @override
  ({String recognition, String speech}) nativePicks =
      (recognition: nativeRecognition.id, speech: nativeSpeech.id);

  /// Set to make [start] throw, which is a model that will not load or a
  /// microphone the user said no to.
  String? refusal;

  FakeVoiceSession? session;

  /// What the last [start] was asked to listen with. Null is a session that
  /// only speaks, which is what reading one message out asks for.
  RecognitionModel? listeningWith;

  /// What the last [start] was asked to hear and speak in.
  String? startedIn;

  /// What the settings page is offered as languages. Empty is every platform
  /// but Android, and an Android one whose synthesiser would not say.
  List<VoiceLanguage> languages = const [];

  @override
  Future<List<VoiceLanguage>> systemLanguages() async => languages;

  @override
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
    String? language,
  }) async {
    if (refusal != null) throw StateError(refusal!);
    listeningWith = recognition;
    startedIn = language;
    return session = FakeVoiceSession();
  }
}

class FakeVoiceSession implements VoiceSession {
  final List<String> spoken = [];
  final _events = StreamController<VoiceEvent>.broadcast();

  var hushed = 0;
  var disposed = false;

  /// Whether the microphone is open. A session opens shut and the controller
  /// asks for it, which is what taking turns is.
  var listening = false;

  /// How many times it was shut on the utterance in progress rather than over
  /// it, which is what releasing the Talk button asks for.
  var finished = 0;

  @override
  final ValueNotifier<double> level = ValueNotifier(0);

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stopSpeaking() async => hushed++;

  @override
  Future<void> setListening(bool on, {bool finish = false}) async {
    // The contract a real session keeps: asking for what it is already doing
    // costs nothing. Without it a fake counts calls the platform never sees.
    if (on == listening) return;
    listening = on;
    if (!on && finish) finished++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }

  void hear(String text) => _events.add(VoiceHeard(text));
  void fallSilent() => _events.add(const VoiceFellSilent());
  void fail(String message) => _events.add(VoiceFailed(message));
}

/// A Linux or two, without one on disk.
class FakeRootfsStore extends RootfsStore {
  FakeRootfsStore({Set<String> installed = const {}}) : _installed = {...installed};

  final Set<String> _installed;

  final List<String> deleted = [];

  /// Holds a download open, so a test can see a row and a notification
  /// mid-flight. Without it an install lands at once.
  Completer<void>? installing;

  /// Fails the next install with this, then clears itself.
  Object? failNext;

  @override
  Future<Set<String>> installed() async => {..._installed};

  @override
  Future<String?> directoryOf(Rootfs rootfs) async => directoryOfSync(rootfs.id);

  @override
  String? directoryOfSync(String id) =>
      _installed.contains(id) ? "/rootfs/$id" : null;

  @override
  Stream<DownloadProgress> install(Rootfs rootfs, {required String abi}) async* {
    final image = rootfs.imageFor(abi)!;
    yield DownloadProgress(received: 0, total: image.bytes);
    if (failNext case final error?) {
      failNext = null;
      throw error;
    }
    if (installing != null) await installing!.future;
    yield DownloadProgress(received: image.bytes, total: image.bytes);
    _installed.add(rootfs.id);
  }

  @override
  Future<void> delete(Rootfs rootfs) async {
    deleted.add(rootfs.id);
    _installed.remove(rootfs.id);
  }
}

/// Models that are simply there, or simply are not, like the two catalogs
/// beside it — downloading is tested against the real store and a real socket.
class FakeLocalModelStore extends LocalModelStore {
  FakeLocalModelStore({Set<String> installed = const {}}) : _installed = {...installed};

  final Set<String> _installed;

  final List<String> deleted = [];

  /// Holds a download open, so a test can see a row and a notification
  /// mid-flight. Without it an install lands at once.
  Completer<void>? installing;

  /// Fails the next install with this, then clears itself.
  Object? failNext;

  @override
  Future<Set<String>> installed() async => {..._installed};

  @override
  String? fileOfSync(LocalModel model) =>
      _installed.contains(model.id) ? "/models/${model.id}/model.gguf" : null;

  @override
  Stream<DownloadProgress> install(LocalModel model) async* {
    yield DownloadProgress(received: 0, total: model.bytes);
    if (installing != null) await installing!.future;
    yield DownloadProgress(received: model.bytes, total: model.bytes);
    _installed.add(model.id);
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    _installed.remove(id);
  }
}

/// The on-device pool with nothing behind it. [served] is what a test asserts
/// on — that asking for a model is what loads it, and with what — and [ready] is
/// whether it gets there, so the failed row can be drawn without a model that
/// will not load.
///
/// [installed] is what the pool would find on disk, and so what the provider
/// offers. It is a separate list from what is running for the reason the real
/// one keeps them apart: every downloaded model is in every picker, and only
/// the ones that have been asked for are loaded.
class FakeLocalLlm extends LocalLlm {
  FakeLocalLlm({
    this.available = true,
    this.devicesFound = const [],
    this.ready = true,
    this.failure = "It would not fit.",
    this.installed = const [],
    this.maxThreads,
    this.baseUrl = "http://127.0.0.1:1/v1",
  });

  /// Where a served model says it is. The default is a port nothing is on, so a
  /// test that only cares that a warm-up was attempted gets a refused
  /// connection rather than a wait; a test about what was actually sent points
  /// this at an `HttpServer` of its own.
  final String baseUrl;

  @override
  final bool available;

  final List<LocalDevice> devicesFound;
  final bool ready;
  final String failure;
  final List<String> installed;

  /// What the cores slider tops out at, and whether it is drawn at all. Null by
  /// default, which takes the slider off the page — a test that wants it sets a
  /// number above one.
  @override
  final int? maxThreads;

  /// One entry per [serve], as it was asked for — including the ones answered
  /// from what was already up, since "it did not start a second copy" is a
  /// thing worth asserting.
  final List<
      ({
        String modelId,
        String? device,
        int? contextLength,
        int maxRunning,
        int? threads,
        bool kvCache,
      })> served = [];

  var stops = 0;

  /// Held open where a test wants a model that has not finished loading: [serve]
  /// publishes its row and then waits on this, which is where the settings page
  /// draws one and where a warm-up sits until it has a server to warm.
  Completer<void>? loading;

  @override
  final ValueNotifier<List<LocalLlmState>> running = ValueNotifier(const []);

  @override
  Future<List<LocalDevice>> devices() async => devicesFound;

  @override
  Future<LocalEndpoint> serve(
    String modelId, {
    String? device,
    int? contextLength,
    int maxRunning = 1,
    int? threads,
    bool kvCache = false,
  }) async {
    served.add((
      modelId: modelId,
      device: device,
      contextLength: contextLength,
      maxRunning: maxRunning,
      threads: threads,
      kvCache: kvCache,
    ));
    final state = LocalLlmState(
      modelId: modelId,
      phase: ready ? LocalLlmPhase.ready : LocalLlmPhase.failed,
      device: device,
      contextLength: contextLength,
      failure: ready ? null : failure,
    );
    running.value = [
      ...running.value.where((each) => each.modelId != modelId).take(maxRunning - 1),
      state,
    ];
    if (loading != null) await loading!.future;
    if (!ready) throw LocalLlmFailure(failure);
    return LocalEndpoint(
      baseUrl: baseUrl,
      apiKey: "k",
      contextLength: contextLength ?? 0,
    );
  }

  @override
  Future<void> stopAll() async {
    stops++;
    running.value = const [];
  }

  @override
  LlmProviderConfig? get provider => installed.isEmpty
      ? null
      : LlmProviderConfig(
          id: localProviderId,
          label: "On-device",
          api: LlmApi.openai,
          baseUrl: "",
          models: installed,
        );
}

/// Models that are simply there, or simply are not. Downloading is tested
/// against the real store and a real socket — see `voice_model_store_test.dart`
/// — so this only has to answer what is installed.
class FakeVoiceModelStore extends VoiceModelStore {
  FakeVoiceModelStore({Set<String> installed = const {}})
      : _installed = {...installed};

  final Set<String> _installed;

  final List<String> deleted = [];

  // A copy, the way a real store answers: the same set handed back twice is one
  // a provider cannot tell has changed.
  @override
  Future<Set<String>> installed() async => {..._installed};

  @override
  Future<String?> directoryOf(VoiceModel model) async =>
      _installed.contains(model.id) ? "/models/${model.id}" : null;

  /// As [FakeRootfsStore.installing].
  Completer<void>? installing;

  /// What the next download fails with, or null for one that works.
  String? failWith;

  /// How many times the first progress event is reported, for a test about what
  /// a run of events that say the same thing costs.
  int repeats = 1;

  @override
  Stream<DownloadProgress> install(VoiceModel model) async* {
    for (var i = 0; i < repeats; i++) {
      yield DownloadProgress(received: 0, total: model.bytes);
    }
    if (failWith != null) throw StateError(failWith!);
    if (installing != null) await installing!.future;
    yield DownloadProgress(received: model.bytes, total: model.bytes);
    _installed.add(model.id);
  }

  @override
  Future<void> delete(VoiceModel model) async {
    deleted.add(model.id);
    _installed.remove(model.id);
  }
}

/// The Remotes half of the sidebar with no hub under it. Every test that is
/// not about sync gets an empty list; a sync one seeds the rows it wants.
class FakePairedDevices extends PairedDevices {
  FakePairedDevices(this.peers);

  final Map<String, PeerState> peers;

  @override
  Map<String, PeerState> build() => peers;
}

class FakeDeviceProjects extends DeviceProjects {
  FakeDeviceProjects(this.projects);

  final Map<String, List<String>> projects;

  @override
  Map<String, List<String>> build() => projects;
}

/// A paired device's project as it answered, or not yet where it is absent.
class FakeRemoteProject extends RemoteProjectNotifier {
  FakeRemoteProject(super.project, this.answers);

  final Map<ProjectRef, RemoteProject> answers;

  @override
  RemoteProject? build() => answers[project];
}

class FakeRemoteChats extends RemoteChats {
  FakeRemoteChats(this.entries);

  final List<RemoteChatEntry> entries;

  @override
  List<RemoteChatEntry> build() => entries;
}

/// A [SecretStore] with nothing behind it. `encrypted` is false, which is
/// what the Sync page warns about — the weakest of the three ports.
class FakeSecretStore implements SecretStore {
  final _items = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String key) async => _items[key];

  @override
  Future<void> write(String key, Uint8List value) async => _items[key] = value;

  @override
  Future<void> delete(String key) async => _items.remove(key);

  @override
  bool get encrypted => false;
}

/// A [DeviceRegistry] in memory: paired devices with no `devices.json` under
/// them, for the tests about what the Sync page draws.
class FakeDeviceRegistry implements DeviceRegistry {
  FakeDeviceRegistry([List<PairedDevice> devices = const []]) {
    for (final device in devices) {
      _devices[device.id] = device;
    }
  }

  final _devices = <String, PairedDevice>{};
  final _secrets = <String, String>{};

  @override
  Future<List<PairedDevice>> list() async => _devices.values.toList();

  @override
  Future<PairedDevice?> byId(String id) async => _devices[id];

  @override
  Future<void> add(PairedDevice device) async => _devices[device.id] = device;

  @override
  Future<void> remove(String id) async => _devices.remove(id);

  @override
  Future<void> markSeen(String id, {List<String>? addresses}) async {
    final device = _devices[id];
    if (device == null) return;
    device.lastSeenAt = DateTime.now();
    if (addresses != null && addresses.isNotEmpty) device.addresses = addresses;
  }

  @override
  Future<void> rename(String id, String name) async {
    final device = _devices[id];
    if (device == null) return;
    _devices[id] = device.withName(name);
  }

  @override
  Future<String?> pairingSecret(String id) async => _secrets[id];

  @override
  Future<void> setPairingSecret(String id, String secret) async =>
      _secrets[id] = secret;
}

/// A relay room with nobody else in it. What the hub does with a relay URL is
/// dial it, so a test that only wants the window open needs somewhere for the
/// dial to land — a real one is a DNS lookup and a socket, in a test that is
/// about neither.
class FakeRelaySignaling implements RelaySignaling {
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();

  /// Every room joined, as `(relayUrl, room, role)`.
  final dialled = <(String, String, String)>[];

  /// Everything the hub said into the room.
  final sent = <Map<String, Object?>>[];

  /// A [RelayDial] over this one, recording what it was asked for.
  Future<RelaySignaling> dial({
    required String relayUrl,
    required String room,
    required String role,
  }) async {
    dialled.add((relayUrl, room, role));
    return this;
  }

  /// A message from the other side of the room.
  void arrive(Map<String, dynamic> message) => _incoming.add(message);

  @override
  Stream<Map<String, dynamic>> get messages => _incoming.stream;

  @override
  Future<void> send(Map<String, Object?> json) async => sent.add(json);

  @override
  Future<Map<String, dynamic>> waitFor(String field,
          {Duration timeout = const Duration(seconds: 45)}) =>
      messages.firstWhere((m) => m.containsKey(field)).timeout(timeout);

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// A device as the registry holds one, for seeding the paired list.
PairedDevice testPairedDevice(String id, {String name = "Desktop"}) =>
    PairedDevice(
      id: id,
      name: name,
      publicKey: "cHVibGlj",
      addedAt: DateTime.utc(2026),
    );

/// A mirrored chat's view, already resolved. What the real controller derives
/// from a live mirror — and the offline status line it puts there — is pinned
/// in `sync_hub_pair_test.dart` over two real hubs; here the page is the
/// subject and there is no wire.
class FakeMirrorChat extends MirrorChatController {
  FakeMirrorChat(super.chatId, this.views);

  final Map<String, ChatViewState> views;

  @override
  ChatViewState build() => views[chatId] ?? ChatViewState();
}

/// Two [ByteChannel]s wired to each other, for the tests about everything
/// above a transport: the handshake, the framing, and the hub on top. One
/// message in is one message out, in order — which is all a real data channel
/// promises, and all any of that code may assume.
(LoopbackChannel, LoopbackChannel) loopbackPair() {
  final a = LoopbackChannel();
  final b = LoopbackChannel();
  a.other = b;
  b.other = a;
  return (a, b);
}

class LoopbackChannel implements ByteChannel {
  LoopbackChannel? other;

  /// Every frame's size as it goes out, for the tests about what has to be
  /// paged. A real data channel refuses one past its maximum; this one does
  /// not, so a test has to look.
  void Function(int bytes)? _sizes;

  void watchSends(void Function(int bytes) sizes) => _sizes = sizes;
  // Single-subscription like the real one, so a test exercises the buffering
  // rather than a broadcast stream's dropping.
  final _incoming = StreamController<Uint8List>();
  var _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    _sizes?.call(bytes.length);
    if (_closed) throw StateError("loopback closed");
    final peer = other!;
    if (peer._closed) throw StateError("peer closed");
    peer._incoming.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
    // Both ends, the way a real transport does: closing one side of a data
    // channel is something the other side is told about. Closing only this
    // one left the peer waiting out its timeouts for a channel already gone.
    await other?.close();
  }
}

/// A [TriggerTurnDriver] that records what it was asked and returns a canned
/// result. The runner's unit tests care about the orchestration — chat
/// creation, stamping, the sidebar — not the turn itself, which is
/// [ChatController]'s job and tested through it.
class FakeTriggerTurnDriver implements TriggerTurnDriver {
  final List<({String chatId, String prompt})> calls = [];
  TriggerOutcome outcome = TriggerOutcome.done;
  String snippet = "";

  @override
  Future<({TriggerOutcome outcome, String snippet})> send(
      String chatId, String prompt) async {
    calls.add((chatId: chatId, prompt: prompt));
    return (outcome: outcome, snippet: snippet);
  }
}

/// The file system's push, driven by hand: the roots a kind asked to watch,
/// and the events [push] delivers to every watcher. The one
/// [FileWatches] fake — the file-kind tests and the manager-through-file
/// tests drive the same one, so a shape change is one edit.
class FakeFileWatches implements FileWatches {
  final _events = StreamController<FileWatchEvent>.broadcast();
  final roots = <String>[];

  @override
  bool get available => true;

  @override
  Stream<FileWatchEvent> watch(String root) {
    roots.add(root);
    return _events.stream;
  }

  /// One change under one of the watched roots.
  void push(String path, FileEvent kind) =>
      _events.add(FileWatchEvent(path: path, kind: kind));
}

/// A [TriggerRuns] that records what it was asked and hangs on demand —
/// the manager tests' stand-in, beside [FakeTriggerTurnDriver]. Stamps
/// [Trigger.lastFiredAt] like the real runner does (before the run), since
/// "one stamp owner" is the design: the manager's replacement carries this
/// rather than writing its own.
class StubRuns implements TriggerRuns {
  final firedIds = <String>[];
  final reasons = <String>[];

  /// The stamp the manager's replacement carries, written through the list
  /// the way the real runner's `onTriggerFired` is. A clock the tests pin.
  DateTime Function()? nowOf;

  /// Where the stamp lands. Wired by the test to its list's `replace`.
  Future<void> Function(Trigger)? stampThrough;

  /// Set when a test wants a run to hang, the way a real turn does.
  Completer<void>? gate;

  @override
  Future<TriggerRunResult> run(Trigger trigger, String reason, List<String> projects) async {
    firedIds.add(trigger.id);
    reasons.add(reason);
    final stamped = nowOf == null ? trigger : trigger.copyWith(lastFiredAt: nowOf!());
    await stampThrough?.call(stamped);
    if (gate != null) await gate!.future;
    return (chatId: "chat-${trigger.id}", outcome: TriggerOutcome.done, snippet: "done", targetGone: false);
  }
}
