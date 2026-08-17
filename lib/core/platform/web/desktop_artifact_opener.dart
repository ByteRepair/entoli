/// Web stub. The desktop artifact temp-file writer is never used on web, where
/// the artifact's files are read from IndexedDB and opened as a blob. Behind
/// the conditional import so the name resolves on every platform.
Future<String?> writeArtifactTemp(String dir, String entryFile) async => null;