import "package:entoli_chat/app/handoff.dart";
import "package:entoli_chat/domain/agent_browser.dart"
    show AgentBrowser, BrowserTab;
import "package:entoli_chat/ui/chat/activity/page_hand_off.dart";
import "package:entoli_chat/ui/widgets/notice.dart";
import "package:entoli_chat/ui/widgets/text_file_page.dart";
import "package:flutter/material.dart";
import "package:path/path.dart" as p;

/// The viewer's hand-off. A detail, a file, an artifact and the plan open
/// here, read only; what only a running app has — a skill to install, the
/// agent's browser — says to open the chat in Entoli.
class SharedChatHandOff extends PageHandOff {
  const SharedChatHandOff(super.context);

  @override
  Future<void> openFile(String path) async {
    final download = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            TextFilePage(path: path, name: p.basename(path), readOnly: true),
      ),
    );
    if (download == true) {
      await attempt(() => container.read(fileHandoffProvider).open(path));
    }
  }

  @override
  Future<void> installSkill(String chatId, String installId) async =>
      _inApp("A skill");

  @override
  Future<void> openBrowser(AgentBrowser browser, BrowserTab tab) async =>
      _inApp("The agent's browser");

  void _inApp(String what) {
    if (context.mounted) notify(context, "$what opens in Entoli.");
  }
}
