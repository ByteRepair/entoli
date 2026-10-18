import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/memory/store.dart";
import "../../data/sync/sync_hub.dart";
import "../../domain/app_settings.dart";
import "../../domain/chat_meta.dart";
import "../../domain/chat_repository.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show localProject;
import "../../domain/project_settings.dart";
import "../../domain/prompt_library.dart";
import "../../domain/sync/protocol.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart" show selectedChatIdProvider, selectedProjectProvider;
import "chat_controller.dart";

/// This device's end of a chat somebody else is watching or driving.
///
/// Nothing about a turn moves: a prompt typed on a mirror is run *here*, by
/// the same [ChatController] a locally typed one goes through, against the
/// same model and the same workspace. What crosses the wire is the asking and
/// the answering.
///
/// It holds one controller open per watched chat, which is what makes a turn
/// visible at the other end at all — whether one is running, what it is
/// waiting to be allowed, what it is waiting to be told. None of that is in
/// `conv.jsonl`, so nothing else would carry it.
///
/// Read once for its effect, like `TurnKeepAlive`: it registers itself on the
/// hub in its constructor and nothing ever asks it anything.
class RemoteTurnDriver implements RemoteTurns {
  RemoteTurnDriver(this._ref, this._hub) {
    _hub.remoteTurns = this;
    _hub.servedChats.addListener(_served);
    _served();
    _hub.servedProjects.addListener(_servedProjects);
    _servedProjects();
    // Every open project inherits from these.
    _app = _ref.listen<AppSettings>(appSettingsProvider, (_, _) {
      for (final project in _projects.keys) {
        _hub.publishProject(project);
      }
    });
  }

  late final ProviderSubscription<AppSettings> _app;
  final _projects = <String?, List<ProviderSubscription<Object>>>{};

  void _servedProjects() {
    final served = _hub.servedProjects.value;
    for (final project in _projects.keys.toList()) {
      if (served.contains(project)) continue;
      for (final subscription in _projects.remove(project)!) {
        subscription.close();
      }
    }
    for (final project in served) {
      _projects.putIfAbsent(project, () => [
            _ref.listen<ProjectSettings>(
                projectSettingsProvider(project), (_, _) => _hub.publishProject(project)),
            _ref.listen<PromptLibrary>(
                promptLibraryProvider(project), (_, _) => _hub.publishPrompts(project)),
          ]);
    }
  }

  final Ref _ref;
  final SyncHub _hub;
  final _watching = <String, ProviderSubscription<ChatViewState>>{};

  /// What was last sent for each chat. `ChatViewState` has no `==` and is
  /// replaced on every flush of a streaming reply — tens of times a second —
  /// while none of what this message carries changes between them. The words
  /// themselves reach the mirror as records; this is only the turn around
  /// them.
  final _published = <String, String>{};

  ChatController _of(String chatId) =>
      _ref.read(chatControllerProvider(chatId).notifier);

  /// The controller is held by the subscription rather than by the page: a
  /// mirror can be reading a chat this device has nothing on screen for.
  void _served() {
    final served = _hub.servedChats.value;
    for (final chatId in _watching.keys.toList()) {
      if (served.contains(chatId)) continue;
      _watching.remove(chatId)?.close();
      _published.remove(chatId);
    }
    for (final chatId in served) {
      _watching.putIfAbsent(
        chatId,
        () => _ref.listen<ChatViewState>(
          chatControllerProvider(chatId),
          (_, view) => _publish(chatId, view),
          fireImmediately: true,
        ),
      );
    }
  }

  void _publish(String chatId, ChatViewState view) {
    final approvals = [
      for (final list in view.approvals.values) ...list
    ];
    final asks = [
      for (final asked in view.questions.values) ...asked,
    ];
    final signature = [
      view.isRunning,
      view.status,
      view.retry,
      [for (final a in approvals) a.id],
      [for (final a in asks) a.id],
    ].join("\u0000");
    if (_published[chatId] == signature) return;
    _published[chatId] = signature;
    _hub.publishTurn(
      chatId,
      running: view.isRunning,
      approvals: approvals,
      asks: [
        for (final asked in asks)
          SyncAsk(id: asked.id, argumentsJson: asked.argumentsJson),
      ],
      status: view.status,
      retry: view.retry,
    );
  }

  @override
  void prompt(String chatId, String text, {List<Attachment> attachments = const []}) =>
      _of(chatId).send(text, attachments: attachments);

  @override
  void resume(String chatId) => _of(chatId).resume();

  @override
  void abort(String chatId) => _of(chatId).abort();

  @override
  void approve(String chatId, String approvalId, bool allow) => _of(chatId)
      .respondApproval(
          approvalId, allow ? ApprovalResponse.allow : ApprovalResponse.deny);

  @override
  void answer(String chatId, String requestId, List<String?> answers) =>
      _of(chatId).answerQuestions(requestId, answers);

  @override
  void editResend(String chatId, String messageId, String text) =>
      _of(chatId).editAndResend(messageId, text);

  @override
  void regenerate(String chatId, String messageId) =>
      _of(chatId).regenerate(messageId);

  @override
  void stepThread(String chatId, String messageId, int step) =>
      _of(chatId).stepThread(messageId, step);

  @override
  void deleteThread(String chatId, String messageId) =>
      _of(chatId).deleteThread(messageId);

  ChatRepository get _repo => _ref.read(chatRepositoryProvider);

  // The hub has checked each of these is one of this device's chats.

  /// The controller to tell, where there is one: building it would load a
  /// conversation nobody is looking at — a rename from a paired sidebar.
  ChatController? _openOf(String chatId) =>
      _ref.exists(chatControllerProvider(chatId)) ? _of(chatId) : null;

  @override
  Future<void> saveState(String chatId, ChatState state, {required bool reanchor}) async {
    final written = await _repo.saveState(state, reanchor: reanchor);
    _openOf(chatId)?.applyState(written);
    _ref.invalidate(chatListProvider);
  }

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) => _repo.saveMeta(chatId, meta);

  @override
  Future<void> retitle(String chatId, String title) async {
    await _repo.retitle(chatId, title);
    _openOf(chatId)?.applyTitle(title);
    _ref.invalidate(chatListProvider);
  }

  @override
  Future<void> delete(String chatId) async {
    if (_ref.read(selectedChatIdProvider) == chatId) {
      _ref.read(selectedChatIdProvider.notifier).select(null);
    }
    await _repo.deleteChat(chatId);
    _ref.invalidate(chatListProvider);
  }

  @override
  Future<String> startChat(String? project) async {
    final chat = await _repo.createChat(project: project);
    _ref.invalidate(chatListProvider);
    return chat.state.id;
  }

  @override
  ProjectSettings projectSettings(String? project) =>
      _ref.read(projectSettingsProvider(project));

  @override
  AppSettings get appSettings => _ref.read(appSettingsProvider);

  @override
  Future<void> writeProject(String? project, ProjectSettings settings) =>
      _ref.read(projectSettingsProvider(project).notifier).replace(settings);

  @override
  Future<void> createProject(String name) async {
    await _repo.createProject(name);
    _ref.invalidate(projectListProvider);
  }

  /// What `deleteProject` on the settings page does, less asking: the user
  /// asked on the device they deleted it from.
  @override
  Future<void> deleteProject(String name) async {
    await _repo.deleteProject(name);
    if (_ref.read(selectedProjectProvider) == localProject(name)) {
      _ref.read(selectedProjectProvider.notifier).select(localProject(null));
      _ref.read(selectedChatIdProvider.notifier).select(null);
    }
    if (_ref.read(appSettingsProvider).assistantProject == name) {
      await _ref.read(appSettingsProvider.notifier).setAssistantProject(null);
    }
    _ref.invalidate(projectListProvider);
    _ref.invalidate(chatListProvider);
  }

  @override
  PromptLibrary library(String? project) => _ref.read(promptLibraryProvider(project));

  @override
  Memories memories(String? project) {
    final config = _ref.read(appConfigProvider);
    return MemoryStore(config.fs, config.memoryDir(project: project));
  }

  void dispose() {
    _hub.servedProjects.removeListener(_servedProjects);
    for (final subscription in _projects.values.expand((s) => s)) {
      subscription.close();
    }
    _projects.clear();
    _app.close();
    _hub.servedChats.removeListener(_served);
    for (final subscription in _watching.values) {
      subscription.close();
    }
    _watching.clear();
    _published.clear();
  }
}

final remoteTurnDriverProvider = Provider<RemoteTurnDriver>((ref) {
  final driver = RemoteTurnDriver(ref, ref.watch(syncHubProvider));
  ref.onDispose(driver.dispose);
  return driver;
});
