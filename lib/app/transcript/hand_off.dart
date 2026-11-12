/// What a frontend opens with a page of its own from the conversation: a
/// file, an artifact, a skill the model drafted, the plan, a link. Each
/// frontend implements it where it can push a page — Flutter's over the
/// context of what was tapped, the native one over its own navigation — and
/// hands it to whatever the core asks to run.
abstract interface class TranscriptHandOff {
  Future<void> openFile(String path);

  Future<void> openArtifact(
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  });

  Future<void> installSkill(String chatId, String installId);

  Future<void> openPlan(String chatId);

  Future<void> openLink(String href);

  /// Runs [action], saying what it threw the frontend's way.
  Future<void> attempt(Future<void> Function() action);
}
