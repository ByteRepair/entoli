/// Opens an artifact on the web platform, where there is no `file://` path.
/// The artifact's files are read from IndexedDB, assembled into blob URLs,
/// and opened in a new tab. Non-web platforms use `file://` paths directly,
/// via a conditional import that swaps the implementation.
abstract interface class WebArtifactOpener {
  Future<void> open(String chatId, String artifactId, {required String entryFile});
}