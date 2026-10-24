import "dart:ffi";
import "dart:io";
import "dart:isolate";

import "package:ffi/ffi.dart";

/// Takes write permission off a whole tree, or gives it back to the owner.
///
/// Through libc's `chmod` and Windows' file attributes rather than the
/// `chmod` binary: iOS lets an app spawn no process, and iSH reading the
/// workspace there is one of the guests this exists to hold back.
///
/// [executable] gives every file its execute bit on the way to read-only,
/// for a skill's scripts, which arrive from embedded data with none.
Future<void> setTreeWritable(List<String> paths,
        {required bool writable, bool executable = false}) =>
    Isolate.run(() {
      for (final path in paths) {
        _walk(path, writable: writable, executable: executable);
      }
    });

void _walk(String root, {required bool writable, required bool executable}) {
  final top = Directory(root);
  if (!top.existsSync()) return;
  final windows = Platform.isWindows;
  void set(FileSystemEntity entity, bool isDir) => windows
      ? _setWindows(entity.path, isDir: isDir, writable: writable)
      : _setPosix(entity.path,
          isDir: isDir, writable: writable, executable: executable);
  // The root first when unlocking, so a later listing can never be what
  // fails; listing itself only needs read and execute, which a lock keeps.
  if (writable) set(top, true);
  for (final entity in top.listSync(recursive: true, followLinks: false)) {
    // chmod follows a link, which would reach whatever it points at.
    if (entity is Link) continue;
    set(entity, entity is Directory);
  }
  if (!writable) set(top, true);
}

typedef _ChmodC = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);

final _chmod =
    DynamicLibrary.process().lookupFunction<_ChmodC, _ChmodDart>("chmod");

void _setPosix(String path,
    {required bool isDir, required bool writable, required bool executable}) {
  final mode = FileStat.statSync(path).mode & 0x1ff;
  final next = writable
      ? mode | 0x80 // u+w
      : (mode & ~0x92) | (isDir || executable ? 0x49 : 0); // a-w, a+x
  if (next == mode) return;
  final native = path.toNativeUtf8();
  try {
    _chmod(native, next);
  } finally {
    malloc.free(native);
  }
}

typedef _GetAttrsC = Uint32 Function(Pointer<Utf16>);
typedef _GetAttrsDart = int Function(Pointer<Utf16>);
typedef _SetAttrsC = Int32 Function(Pointer<Utf16>, Uint32);
typedef _SetAttrsDart = int Function(Pointer<Utf16>, int);

const _readOnly = 0x1;
const _invalid = 0xFFFFFFFF;

/// Files only: Windows reads a directory's read-only bit as "has a custom
/// icon", and refuses no write for it.
void _setWindows(String path, {required bool isDir, required bool writable}) {
  if (isDir) return;
  final kernel = DynamicLibrary.open("kernel32.dll");
  final get = kernel.lookupFunction<_GetAttrsC, _GetAttrsDart>("GetFileAttributesW");
  final set = kernel.lookupFunction<_SetAttrsC, _SetAttrsDart>("SetFileAttributesW");
  final native = path.toNativeUtf16();
  try {
    final attrs = get(native);
    if (attrs == _invalid) return;
    set(native, writable ? attrs & ~_readOnly : attrs | _readOnly);
  } finally {
    malloc.free(native);
  }
}
