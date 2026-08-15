/// Where the app's own files are: the directory everything is resolved under,
/// the directories a chat's files sit in, and the small JSON documents beside
/// them. A port, because a browser has none of it and still has to be given
/// somewhere to put them.
///
/// Chats are not here. They are a `ChatStore`, which is a whole store rather
/// than three calls, and the one a browser gets holds them in fields.
abstract class Storage {
  const Storage();

  /// Where everything else is resolved under. Asked rather than known, because
  /// a platform may have to answer it (Android's app-private directory).
  Future<String> dataDir();

  void ensureDir(String path);

  /// Null where nothing has been written, which is the caller's cue to use its
  /// defaults rather than an error.
  String? read(String path);

  void write(String path, String text);
}
