import "package:file/file.dart";

extension FileErrors on FileSystemException {
  /// Nothing was at the path. The disk says so with dart:io's
  /// `PathNotFoundException`, memory with the plain exception, both `ENOENT`.
  bool get isNotFound => osError?.errorCode == ErrorCodes.ENOENT;
}
