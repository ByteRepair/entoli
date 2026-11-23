import "dart:async";

import "package:path/path.dart" as p;

import "package:entoli_chat/domain/agent_browser.dart"
    show AgentBrowser, BrowserTab;
import "package:entoli_chat/ui/chat/activity/page_hand_off.dart";
import "package:entoli_chat/ui/widgets/text_file_page.dart" show openTextFile;
import "../../selection.dart" show selectedProjectProvider;
import "../../skills/skill_install_preview.dart" show openSkillInstall;
import "../../widgets/prompt_field.dart" show PromptPage;
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

  /// On a page of its own with the composer's field: a message is often
  /// long, and the `/` and `@` it was written with complete here the way
  /// they did there.
  @override
  Future<String?> editMessage(String text) {
    final at = container.read(selectedProjectProvider);
    return PromptPage.open(
      context,
      title: "Edit message",
      text: text,
      hint: "Message",
      project: at.project,
      device: at.device,
      confirmLabel: "Send",
    );
  }
}
