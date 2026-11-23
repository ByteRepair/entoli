import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../../app/transcript/activity.dart";
import "../../../domain/agent_browser.dart" show AgentBrowser, BrowserTab;
import "../../../providers.dart";
import "../../skills/skill_install_preview.dart" show openSkillInstall;
import "../../widgets/dialogs.dart" show say;
import "../../widgets/text_file_page.dart" show openTextFile;
import "../plan_page.dart" as plan_page;
import "../widgets/browser_strip.dart" show openBrowserTab;
import "card.dart" show showActivityDetail;

/// The app's hand-off: a page pushed over the [context] of what was tapped.
class ContextHandOff implements TranscriptHandOff {
  const ContextHandOff(this.context);

  final BuildContext context;

  ProviderContainer get _container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  Future<void> openFile(String path) async =>
      unawaited(openTextFile(context, path, p.basename(path)));

  @override
  Future<void> openArtifact(
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) => _container
      .read(linkOpenerProvider)
      .openArtifact(
        context,
        chatId,
        artifactId,
        entryFile: entryFile,
        title: title,
      );

  @override
  Future<void> installSkill(String chatId, String installId) =>
      openSkillInstall(context, chatId: chatId, installId: installId);

  @override
  Future<void> openPlan(String chatId) async =>
      plan_page.openPlan(context, chatId);

  @override
  Future<void> openDetail(OpensDetail detail) =>
      showActivityDetail(context, detail);

  @override
  Future<void> openBrowser(AgentBrowser browser, BrowserTab tab) async =>
      openBrowserTab(context, browser, tab);

  @override
  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (context.mounted) say(context, error);
    }
  }
}
