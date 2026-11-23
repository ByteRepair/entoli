import "dart:async";

import "package:path/path.dart" as p;

import "package:entoli_chat/domain/agent_browser.dart"
    show AgentBrowser, BrowserTab;
import "package:entoli_chat/ui/chat/activity/page_hand_off.dart";
import "package:entoli_chat/ui/widgets/text_file_page.dart" show openTextFile;
import "../../skills/skill_install_preview.dart" show openSkillInstall;
import "../widgets/browser_strip.dart" show openBrowserTab;

/// The app's hand-off: a page pushed over the context of what was tapped.
class ContextHandOff extends PageHandOff {
  const ContextHandOff(super.context);

  @override
  Future<void> openFile(String path) async =>
      unawaited(openTextFile(context, path, p.basename(path)));

  @override
  Future<void> installSkill(String chatId, String installId) =>
      openSkillInstall(context, chatId: chatId, installId: installId);

  @override
  Future<void> openBrowser(AgentBrowser browser, BrowserTab tab) async =>
      openBrowserTab(context, browser, tab);
}
