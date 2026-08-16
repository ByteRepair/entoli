import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:agent_chat/domain/app_icon.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/attachment_picker.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_store.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

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

class FakeBackend implements AgentBackend {
  var _created = 0;

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
  }

  @override
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response) async {}

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
  Future<ChatMeta> loadMeta(String chatId) async => _metas[chatId] ?? ChatMeta();

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) async => _metas[chatId] = meta;
}
