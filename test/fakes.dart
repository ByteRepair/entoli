import "dart:async";
import "dart:convert";

import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/local_pool_client.dart";
import "package:agent_chat/data/builtin/llm/local_prefill.dart";
import "package:agent_chat/domain/app_icon.dart";
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
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/voice.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:agent_chat/domain/download.dart";
import "package:agent_chat/domain/rootfs.dart";
import "package:agent_chat/domain/rootfs_store.dart";
import "package:agent_chat/domain/voice_model_store.dart";
import "package:uuid/uuid.dart";

/// A [LinkOpener] that records what it was asked to open, for UI tests that
/// assert on the call rather than on a browser opening.
class FakeLinkOpener implements LinkOpener {
  FakeLinkOpener();

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

/// Two providers, two models each, deliberately not in alphabetical order so
/// tests can assert the UI sorts them.
const testModels = [
  ModelOption(providerId: "ollama-cloud", modelId: "llama-3", label: "Llama 3"),
  ModelOption(providerId: "ollama-cloud", modelId: "qwen-2.5", label: "Qwen 2.5"),
  ModelOption(providerId: "anthropic", modelId: "claude-sonnet-4", label: "Claude Sonnet 4"),
  ModelOption(providerId: "anthropic", modelId: "claude-haiku-3", label: "Claude Haiku 3"),
];

/// A library whose commands include two names sharing a prefix, so tests can
/// assert the menu filters, and whose entries are deliberately out of order.
PromptLibrary testLibrary() => PromptLibrary([
      _doc(CompletionKind.command, "review", "review changes"),
      _doc(CompletionKind.command, "revert", "undo the last turn"),
      _doc(CompletionKind.command, "init", "guided AGENTS.md setup"),
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

/// The platform's hold on the process, which a test has none of. Records what
/// it was told of each kind, and [stop] is one of the notifications' Stop being
/// pressed.
class FakeBackgroundWork implements BackgroundWork {
  final List<int> told = [];
  final List<bool> listened = [];
  final List<DownloadNotice?> downloads = [];
  final List<String?> prefills = [];
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
  /// A launch waiting to be claimed. Taken once, the way the real one is.
  bool pending = false;

  final _arrived = StreamController<void>.broadcast();

  @override
  Stream<void> get launched => _arrived.stream;

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

  final List<({String prompt, String model, String provider})> questions = [];

  /// What `ask` answers. Null is a model that could not answer.
  String? scriptedAnswer;

  @override
  Future<String?> ask(String prompt,
      {required String model, required String provider}) async {
    questions.add((prompt: prompt, model: model, provider: provider));
    return scriptedAnswer;
  }

  final List<
      ({
        String text,
        List<Attachment> attachments,
        List<Message> history,
        TurnSettings settings,
      })> prompts = [];

  /// What the next turn streams back. Defaults to an immediate, empty reply.
  List<AgentEvent> scriptedEvents = const [DoneEvent()];

  /// When set, the turn stays open after the scripted events, the way a real
  /// one does while the backend is still working.
  Completer<void>? hold;

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [],
      List<Message> history = const [],
      TurnSettings settings = const TurnSettings()}) async* {
    prompts.add((
      text: text,
      attachments: attachments,
      history: history,
      settings: settings,
    ));
    yield* Stream.fromIterable(scriptedEvents);
    if (hold != null) await hold!.future;
  }

  /// The same for `resumeTurn`, minus the prompt it does not have.
  final List<({List<Message> history, TurnSettings settings})> resumes = [];

  @override
  Stream<AgentEvent> resumeTurn(String chatId,
      {List<Message> history = const [],
      TurnSettings settings = const TurnSettings()}) async* {
    resumes.add((history: history, settings: settings));
    yield* Stream.fromIterable(scriptedEvents);
    if (hold != null) await hold!.future;
  }

  final List<List<Message>> resets = [];

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) async {
    resets.add(history);
  }


  var didShutdown = false;

  @override
  Future<void> shutdown() async => didShutdown = true;

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

  @override
  Future<void> disposeChat(String chatId) async => disposed.add(chatId);

  List<ModelOption> modelList = testModels;

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
  final Set<String> _projects = {};

  /// The chat's log, as it has been appended to. What the log tests assert on.
  List<ChatRecord> records(String chatId) => List.unmodifiable(_logs[chatId] ?? const []);

  @override
  Future<void> append(String chatId, List<ChatRecord> records) async =>
      _logs.putIfAbsent(chatId, () => []).addAll(records);

  @override
  Future<void> saveState(ChatState state) async => _states[state.id] = state;

  @override
  Future<Chat> load(String id) async {
    final state = _states[id];
    if (state == null) throw StateError("no chat $id");
    return chatFrom(state, records(id));
  }

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
  Future<String> createArtifact(String chatId, String sourceDir, {String? project}) async {
    final artifactId = const Uuid().v4();
    _artifacts.putIfAbsent(chatId, () => {})[artifactId] = {"index.html": Uint8List.fromList(utf8.encode("<p>"))};
    return artifactId;
  }

  @override
  Future<void> updateArtifact(String chatId, String artifactId, String sourceDir, {String? project}) async {
    // Record that an update happened; the fake doesn't actually copy.
    _artifacts.putIfAbsent(chatId, () => {}).putIfAbsent(artifactId, () => {});
  }

  @override
  Future<Uint8List?> readArtifactFile(
    String chatId, String artifactId, String relativePath, {String? project}) async =>
      _artifacts[chatId]?[artifactId]?[relativePath];

  @override
  Future<String> artifactPath(String chatId, String artifactId, {String? project}) async =>
      "/tmp/test/$chatId/artifacts/$artifactId";

  @override
  Future<ChatMeta> loadMeta(String chatId) async => _metas[chatId] ?? ChatMeta();

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async => _metas[chatId] = meta;
}

/// Listening and speaking, with neither. [hear] is the user saying something
/// and [spoken] is what the reply came out as, which is the pair every voice
/// test is written against.
class FakeVoice extends Voice {
  FakeVoice({this.available = true, this.downloadsModels = true});

  @override
  final bool available;

  /// False is Android, where the engines are the system's: no catalog to draw,
  /// and the pickers offer the sentinels or nothing.
  @override
  final bool downloadsModels;

  /// Set to make [start] throw, which is a model that will not load or a
  /// microphone the user said no to.
  String? refusal;

  FakeVoiceSession? session;

  /// What the last [start] was asked to listen with. Null is a session that
  /// only speaks, which is what reading one message out asks for.
  RecognitionModel? listeningWith;

  @override
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
  }) async {
    if (refusal != null) throw StateError(refusal!);
    listeningWith = recognition;
    return session = FakeVoiceSession();
  }
}

class FakeVoiceSession implements VoiceSession {
  final List<String> spoken = [];
  final _events = StreamController<VoiceEvent>.broadcast();

  var hushed = 0;
  var disposed = false;

  /// Whether the microphone is open, which pausing shuts.
  var listening = true;

  @override
  final ValueNotifier<double> level = ValueNotifier(0);

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stopSpeaking() async => hushed++;

  @override
  Future<void> setListening(bool on) async => listening = on;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }

  void hear(String text) => _events.add(VoiceHeard(text));
  void interrupt() => _events.add(const VoiceInterrupted());
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
