import "dart:async";

import "../core/log.dart";
import "chat_repository.dart";
import "chat_search.dart";
import "intent_action.dart";
import "models.dart";
import "project.dart";
import "turn_sender.dart";

/// A chat as an intent hands it out: what Shortcuts shows of one and what a
/// later action names it by.
final class IntentChat {
  const IntentChat(this._state);

  final ChatState _state;

  Map<String, Object?> toArgs() => {
    "id": _state.id,
    "title": _state.title.orUntitled,
    "project": IntentProject(_state.project).toArgs(),
    "updatedAt": _state.updatedAt.millisecondsSinceEpoch,
    "pinned": _state.pinned,
  };
}

/// A project as an intent hands it out. [dir] null is the default project,
/// which the wire names by its directory: Shortcuts wants an id that is a
/// string. Where an action takes one, a null [IntentProject] is none named,
/// which is not the default project named.
final class IntentProject {
  const IntentProject(this.dir);

  /// The project a wire id names.
  IntentProject.of(String id) : dir = id == defaultProjectDir ? null : id;

  final String? dir;

  Map<String, Object?> toArgs() => {
    "id": dir ?? defaultProjectDir,
    "label": projectLabel(dir),
  };
}

/// What asking a chat something came to. [outcome] is null where the caller
/// did not wait, so the turn is still running and [reply] is empty.
final class AskResult {
  const AskResult(this.chat, {this.reply = "", this.outcome});

  final IntentChat chat;
  final String reply;
  final TurnOutcome? outcome;

  Map<String, Object?> toArgs() => {
    "chat": chat.toArgs(),
    "reply": reply,
    "outcome": outcome?.name ?? "running",
  };
}

/// Puts a chat on screen. The UI's to implement — the domain only knows a
/// chat can be shown.
abstract interface class ChatPresenter {
  void show(ChatState chat);
}

/// What Shortcuts can do with chats, typed. Nothing here knows about the
/// wire or Shortcuts: [ChatIntentAction] adapts it. It runs with no screen
/// — only [open] shows anything — so an action that arrives while the app
/// launches in the background still finds it.
///
/// Only this device's chats: a mirror's are its home device's to list and
/// drive. A turn goes through the same [TurnSender] a trigger's does,
/// so it is the turn the user sees on opening the chat while it runs. It
/// runs under the chat's own settings: an action never loosens what the
/// agent may do, since a shortcut's input can come from anywhere.
final class ChatIntents {
  ChatIntents({
    required this.repo,
    required this.sender,
    required this.presenter,
    required this.isSetUp,
    required this.onListChanged,
  });

  final ChatRepository repo;
  final TurnSender sender;
  final ChatPresenter presenter;

  /// Whether [project]'s setup step, where it has one, has been run.
  final bool Function(String? project) isSetUp;

  /// The sidebar learns about a chat made here.
  final void Function() onListChanged;

  Future<List<IntentProject>> projects() async => [
    for (final dir in everyProject(await repo.listProjects()))
      IntentProject(dir),
  ];

  /// The chats [ids] name, in that order, skipping any that are gone.
  Future<List<IntentChat>> chats(List<String> ids) async {
    final byId = {for (final chat in await _live()) chat.id: chat};
    return [
      for (final id in ids)
        if (byId[id] case final chat?) IntentChat(chat),
    ];
  }

  /// The chats whose title holds [query] — the sidebar's search — newest
  /// first, as the store lists them, in [project] where one is named.
  Future<List<IntentChat>> find({
    String query = "",
    IntentProject? project,
    int? limit,
  }) async {
    if (project != null) await _project(project.dir);
    final found = chatsMatching(
      await _live(),
      query,
    ).where((chat) => project == null || chat.project == project.dir);
    return [
      for (final chat in limit == null ? found : found.take(limit))
        IntentChat(chat),
    ];
  }

  /// A new chat in [project], the default one where none is named.
  Future<IntentChat> newChat({IntentProject? project}) async =>
      IntentChat(await _create(project?.dir));

  Future<void> open(String chatId) async => presenter.show(await _chat(chatId));

  /// [prompt] said in [chatId], or in a new chat in [project] where there is
  /// none. Where [wait], the result is the turn's reply; otherwise the turn
  /// is left running and the result says so.
  Future<AskResult> ask(
    String prompt, {
    String? chatId,
    IntentProject? project,
    bool wait = true,
  }) async {
    if (chatId != null && project != null) {
      throw const IntentRefused("Name a chat or a project, not both.");
    }
    final ChatState chat;
    if (chatId != null) {
      chat = await _chat(chatId);
      _setUp(chat.project);
    } else {
      chat = await _create(project?.dir);
    }
    final turn = sender.send(chat.id, prompt);
    if (!wait) {
      unawaited(
        turn.then<void>(
          (_) {},
          onError: (Object e) =>
              logFailure("intents", "a turn asked for failed", e),
        ),
      );
      return AskResult(IntentChat(chat));
    }
    final ended = await turn;
    return AskResult(
      IntentChat(chat),
      reply: ended.snippet,
      outcome: ended.outcome,
    );
  }

  /// This device's chats, less the temporary ones whose time is up — the
  /// sidebar hides those, and the sweep deletes them.
  Future<List<ChatState>> _live() async => [
    for (final chat in await repo.listChats())
      if (!chat.isExpired()) chat,
  ];

  /// One of this device's chats, by id: the store's, so not a mirror. The
  /// id came from outside and names a directory, so it is one segment or
  /// nothing.
  Future<ChatState> _chat(String chatId) async {
    final chat = isProjectDirName(chatId) ? await repo.loadState(chatId) : null;
    if (chat == null || chat.isExpired()) {
      throw const IntentRefused("That chat no longer exists.");
    }
    return chat;
  }

  Future<ChatState> _create(String? project) async {
    await _project(project);
    _setUp(project);
    final chat = await repo.createChat(project: project);
    onListChanged();
    return chat.state;
  }

  /// [project] checked against the projects there are.
  Future<void> _project(String? project) async {
    if (!await repo.isProject(project)) {
      throw IntentRefused("There is no project called “$project”.");
    }
  }

  void _setUp(String? project) {
    if (!isSetUp(project)) {
      throw IntentRefused(
        "${projectLabel(project)} needs setting up in Entoli first.",
      );
    }
  }
}

/// [ChatIntents] as the actions Shortcuts names, one adapter each: each
/// decodes its own arguments and encodes its own result.
abstract base class ChatIntentAction implements IntentAction {
  const ChatIntentAction(this.chats);

  final ChatIntents chats;

  /// Every one of them, over [chats].
  static List<IntentAction> over(ChatIntents chats) => [
    ProjectsAction(chats),
    ChatsAction(chats),
    FindChatsAction(chats),
    NewChatAction(chats),
    OpenChatAction(chats),
    AskAction(chats),
  ];

  /// The project an action names in `project`, or null where it names none.
  static IntentProject? projectOf(IntentArgs args) {
    final id = args.optionalString("project");
    return id == null ? null : IntentProject.of(id);
  }
}

/// Every project: what Shortcuts offers where an action takes one.
final class ProjectsAction extends ChatIntentAction {
  const ProjectsAction(super.chats);

  @override
  String get id => "projects";

  @override
  Future<Object?> perform(IntentArgs args) async => [
    for (final project in await chats.projects()) project.toArgs(),
  ];
}

/// The chats a saved shortcut names, read again: Shortcuts keeps only ids.
final class ChatsAction extends ChatIntentAction {
  const ChatsAction(super.chats);

  @override
  String get id => "chats";

  @override
  Future<Object?> perform(IntentArgs args) async => [
    for (final chat in await chats.chats(args.strings("ids"))) chat.toArgs(),
  ];
}

final class FindChatsAction extends ChatIntentAction {
  const FindChatsAction(super.chats);

  @override
  String get id => "findChats";

  @override
  Future<Object?> perform(IntentArgs args) async {
    final found = await chats.find(
      query: args.optionalString("query") ?? "",
      project: ChatIntentAction.projectOf(args),
      limit: args.optionalInt("limit"),
    );
    return [for (final chat in found) chat.toArgs()];
  }
}

final class NewChatAction extends ChatIntentAction {
  const NewChatAction(super.chats);

  @override
  String get id => "newChat";

  @override
  Future<Object?> perform(IntentArgs args) async =>
      (await chats.newChat(project: ChatIntentAction.projectOf(args))).toArgs();
}

final class OpenChatAction extends ChatIntentAction {
  const OpenChatAction(super.chats);

  @override
  String get id => "openChat";

  @override
  Future<Object?> perform(IntentArgs args) async {
    await chats.open(args.string("chat"));
    return null;
  }
}

final class AskAction extends ChatIntentAction {
  const AskAction(super.chats);

  @override
  String get id => "ask";

  @override
  Future<Object?> perform(IntentArgs args) async {
    final result = await chats.ask(
      args.string("prompt"),
      chatId: args.optionalString("chat"),
      project: ChatIntentAction.projectOf(args),
      wait: args.flag("wait", orElse: true),
    );
    return result.toArgs();
  }
}
