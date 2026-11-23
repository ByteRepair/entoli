import "package:file/file.dart";
import "package:path/path.dart" as p;

/// Windows' `ERROR_PATH_NOT_FOUND`: a parent directory that is not there,
/// which dart:io also raises as `PathNotFoundException`. Errno 3 elsewhere is
/// `ESRCH`, never a file's.
const _windowsPathNotFound = 3;

extension FileErrors on FileSystemException {
  /// Nothing was at the path. The disk says so with dart:io's
  /// `PathNotFoundException`, memory with the plain exception, both `ENOENT`
  /// or, on Windows, a missing parent's own code.
  bool get isNotFound {
    final code = osError?.errorCode;
    return code == ErrorCodes.ENOENT ||
        (code == _windowsPathNotFound && p.style == p.Style.windows);
  }
}
