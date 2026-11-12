import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../../app/transcript/hand_off.dart";
import "../../../providers.dart";
import "../../../app/pages/marketplace.dart";
import "../../widgets/dialogs.dart" show say;
import "../../../app/pages/text_file.dart";
import "../../app_pages.dart";
import "../plan_page.dart" as plan_page;

/// The conversation's hand-off as the Flutter frontend makes it: a page
/// pushed over the [context] of what was tapped.
class ContextHandOff implements TranscriptHandOff {
  const ContextHandOff(this.context);

  final BuildContext context;

  ProviderContainer get _container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  Future<void> openFile(String path) async => openAppPage(
    context,
    TextFileAppPage(path: path, name: p.basename(path), handsOff: false),
  );

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
  Future<void> installSkill(String chatId, String installId) async =>
      openAppPage(
        context,
        SkillInstallAppPage(chatId: chatId, installId: installId),
      );

  @override
  Future<void> openPlan(String chatId) async =>
      plan_page.openPlan(context, chatId);

  @override
  Future<void> openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri != null) {
      await _container.read(linkOpenerProvider).open(context, uri);
    }
  }

  @override
  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (context.mounted) say(context, error);
    }
  }
}
