import "../../domain/storage.dart";

/// A browser's: the paths are nominal, there are no directories to make, and
/// what is written to a path is kept for the life of the page. Settings made
/// in a tab last until it is reloaded.
class MemoryStorage extends Storage {
  final Map<String, String> _texts = {};

  @override
  Future<String> dataDir() async => "/agent-chat";

  @override
  void ensureDir(String path) {}

  @override
  String? read(String path) => _texts[path];

  @override
  void write(String path, String text) => _texts[path] = text;
}
