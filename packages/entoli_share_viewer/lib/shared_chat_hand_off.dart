import "package:entoli_chat/app/handoff.dart";
import "package:entoli_chat/app/transcript/activity.dart";
import "package:entoli_chat/domain/agent_browser.dart"
    show AgentBrowser, BrowserTab;
import "package:entoli_chat/ui/chat/activity/card.dart";
import "package:entoli_chat/ui/chat/plan_page.dart" as plan_page;
import "package:entoli_chat/ui/widgets/text_file_page.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

/// The viewer's hand-off. A detail, a file, an artifact and the plan open
/// here, read only; what only a running app has — a skill to install, the
/// agent's browser — says to open the chat in Entoli.
class SharedChatHandOff implements TranscriptHandOff {
  const SharedChatHandOff(this.context);

  final BuildContext context;

  ProviderContainer get _container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  Future<void> openDetail(OpensDetail detail) =>
      showActivityDetail(context, detail);

  @override
  Future<void> openFile(String path) async {
    final download = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            TextFilePage(path: path, name: p.basename(path), readOnly: true),
      ),
    );
    if (download == true) {
      await attempt(() => _container.read(fileHandoffProvider).open(path));
    }
  }

  @override
  Future<void> openArtifact(
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) => attempt(
    () => _container
        .read(linkOpenerProvider)
        .openArtifact(
          context,
          chatId,
          artifactId,
          entryFile: entryFile,
          title: title,
        ),
  );

  @override
  Future<void> openPlan(String chatId) async =>
      plan_page.openPlan(context, chatId);

  @override
  Future<void> installSkill(String chatId, String installId) async =>
      _inApp("A skill");

  @override
  Future<void> openBrowser(AgentBrowser browser, BrowserTab tab) async =>
      _inApp("The agent's browser");

  @override
  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      _say("$error");
    }
  }

  void _inApp(String what) => _say("$what opens in Entoli.");

  void _say(String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }
}
