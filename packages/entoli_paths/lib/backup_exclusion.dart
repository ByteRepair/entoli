import "dart:ffi";

import "package:ffi/ffi.dart";

/// Marks [dir] so iCloud and device backups skip it and everything under it.
/// Through CoreFoundation's URL resource key, which is what Apple honours;
/// the old extended attribute is not.
bool excludeFromBackup(String dir) {
  final cf = DynamicLibrary.process();
  final key = cf.lookup<Pointer<Void>>("kCFURLIsExcludedFromBackupKey").value;
  final yes = cf.lookup<Pointer<Void>>("kCFBooleanTrue").value;
  final bytes = dir.toNativeUtf8();
  try {
    final url = _cfUrlFromPath(nullptr, bytes.cast(), bytes.length, 1);
    if (url == nullptr) return false;
    try {
      return _cfUrlSet(url, key, yes, nullptr) != 0;
    } finally {
      _cfRelease(url);
    }
  } finally {
    malloc.free(bytes);
  }
}

typedef _CfUrlFromPathC =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Uint8);
typedef _CfUrlFromPathDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _CfUrlSetC =
    Uint8 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Void>>,
    );
typedef _CfUrlSetDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Void>>,
    );
typedef _CfReleaseC = Void Function(Pointer<Void>);
typedef _CfReleaseDart = void Function(Pointer<Void>);

final _cfUrlFromPath = DynamicLibrary.process()
    .lookupFunction<_CfUrlFromPathC, _CfUrlFromPathDart>(
      "CFURLCreateFromFileSystemRepresentation",
    );
final _cfUrlSet = DynamicLibrary.process()
    .lookupFunction<_CfUrlSetC, _CfUrlSetDart>(
      "CFURLSetResourcePropertyForKey",
    );
final _cfRelease = DynamicLibrary.process()
    .lookupFunction<_CfReleaseC, _CfReleaseDart>("CFRelease");
