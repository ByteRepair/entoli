import "dart:convert";
import "dart:io" as io;
import "dart:typed_data";

import "package:file/file.dart";
import "package:file/memory.dart";

/// dart:io over an in-memory filesystem, for the whole process. A browser has
/// no disk, and lib/ reads its files through dart:io with no port over it, so
/// this is how the app's own readers — and the migration chain — run here.
void useMemoryFileSystem() {
  io.IOOverrides.global = _MemoryIOOverrides(
    MemoryFileSystem(style: FileSystemStyle.posix),
  );
}

final class _MemoryIOOverrides extends io.IOOverrides {
  _MemoryIOOverrides(this._fs);

  final MemoryFileSystem _fs;

  @override
  io.Directory createDirectory(String path) => _fs.directory(path);

  @override
  io.File createFile(String path) => _IoFile(_fs, _fs.file(path));

  @override
  io.Link createLink(String path) => _fs.link(path);

  @override
  Future<io.FileStat> stat(String path) => _fs.stat(path);

  @override
  io.FileStat statSync(String path) => _fs.statSync(path);

  @override
  Future<bool> fseIdentical(String path1, String path2) =>
      _fs.identical(path1, path2);

  @override
  bool fseIdenticalSync(String path1, String path2) =>
      _fs.identicalSync(path1, path2);

  @override
  Future<io.FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      _fs.type(path, followLinks: followLinks);

  @override
  io.FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      _fs.typeSync(path, followLinks: followLinks);

  @override
  io.Directory getCurrentDirectory() => _fs.currentDirectory;

  @override
  void setCurrentDirectory(String path) => _fs.currentDirectory = path;

  @override
  io.Directory getSystemTempDirectory() => _fs.systemTempDirectory;
}

/// A memory file that fails as dart:io's does: a missing path is a
/// [io.PathNotFoundException], which the app catches by that name, where
/// package:file throws the plain [io.FileSystemException] above it.
class _IoFile extends ForwardingFileSystemEntity<File, io.File>
    with ForwardingFile {
  _IoFile(this.fileSystem, this.delegate);

  @override
  final FileSystem fileSystem;

  @override
  final File delegate;

  @override
  File wrapFile(io.File delegate) => _IoFile(fileSystem, delegate as File);

  @override
  Directory wrapDirectory(io.Directory delegate) => delegate as Directory;

  @override
  Link wrapLink(io.Link delegate) => delegate as Link;

  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _sync(() => delegate.readAsStringSync(encoding: encoding));

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _async(() => delegate.readAsString(encoding: encoding));

  @override
  Uint8List readAsBytesSync() => _sync(delegate.readAsBytesSync);

  @override
  Future<Uint8List> readAsBytes() => _async(delegate.readAsBytes);

  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) =>
      _sync(() => delegate.readAsLinesSync(encoding: encoding));

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) =>
      _async(() => delegate.readAsLines(encoding: encoding));

  @override
  Future<File> rename(String newPath) =>
      _async(() async => wrap(await delegate.rename(newPath)));

  @override
  File renameSync(String newPath) =>
      _sync(() => wrap(delegate.renameSync(newPath)));

  @override
  int lengthSync() => _sync(delegate.lengthSync);

  @override
  Future<int> length() => _async(delegate.length);
}

T _sync<T>(T Function() run) {
  try {
    return run();
  } on io.FileSystemException catch (e) {
    throw _likeIo(e);
  }
}

Future<T> _async<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on io.FileSystemException catch (e) {
    throw _likeIo(e);
  }
}

io.FileSystemException _likeIo(io.FileSystemException e) {
  final os = e.osError;
  return os != null && os.errorCode == 2 && e is! io.PathNotFoundException
      ? io.PathNotFoundException(e.path ?? "", os, e.message)
      : e;
}
