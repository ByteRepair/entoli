import "dart:async";

import "../../domain/file_handoff.dart";
import "../../domain/models.dart" show ChatState, ChatTitle;
import "../../domain/project.dart";
import "../../domain/workspace.dart";
import "../../providers.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// Files another app shared to Entoli, and where they go: a project's
/// shared workspace, or a chat's own.
class ShareTargetAppPage extends AppPage {
  ShareTargetAppPage(this.files);

  final List<IncomingFile> files;

  /// Closed: whether anything was saved.
  final _done = Completer<void>();
  Future<void> get done => _done.future;

  @override
  String get address => "share/${files.hashCode}";

  @override
  void closed() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  String title(SettingReader reader) =>
      files.length == 1 ? "Share 1 File To" : "Share ${files.length} Files To";

  Future<SettingNotice?> _save(String dir, String title) async {
    try {
      await writeIncoming(dir, files);
    } catch (e) {
      return SettingNotice("Could not save: $e");
    }
    app
        .read(appPagesProvider.notifier)
        .leave(
          this,
          saying: files.length == 1
              ? "Saved ${files.single.path} to $title"
              : "Saved ${files.length} files to $title",
        );
    return null;
  }

  @override
  List<PageSection> sections(SettingReader reader) {
    final config = reader.watch(appConfigProvider);
    final projects = everyProject(
      reader.watch(projectListProvider).value ?? const [],
    );
    final chats = reader.watch(chatListProvider).value ?? const <ChatState>[];
    return [
      PageSection("projects", "Projects", [
        CollectionController<String?>(
          part("projects", "Projects", hint: UiHint.info),
          items: projects,
          removable: false,
          describe: (project) => CollectionItem(
            projectLabel(project),
            subtitle: "Shared workspace",
            glyph: SettingGlyph.folder,
            editable: false,
            takesImage: false,
            tap: "save",
          ),
          act: (index, _) => _save(
            config.projectWorkspaceDir(project: projects[index]),
            projectLabel(projects[index]),
          ),
        ),
      ]),
      if (chats.isNotEmpty)
        PageSection("chats", "Chats", [
          CollectionController<ChatState>(
            part("chats", "Chats", hint: UiHint.info),
            items: chats,
            removable: false,
            describe: (chat) => CollectionItem(
              chat.title.orUntitled,
              subtitle: projectLabel(chat.project),
              glyph: SettingGlyph.chat,
              editable: false,
              takesImage: false,
              tap: "save",
            ),
            act: (index, _) => _save(
              config.workspaceDir(
                chats[index].id,
                project: chats[index].project,
              ),
              chats[index].title.orUntitled,
            ),
          ),
        ]),
    ];
  }
}
