/// The browser Linux's view of the app's own files: a 9P2000.L server over the
/// app's [FileSystem], which in a browser is IndexedDB. The guest mounts it at
/// the data directory's own path, so `/entoli/projects/default/workspace` is
/// the same directory to a command and to the file tools, with nothing to
/// translate and nothing to copy back. See "The browser's Linux" in
/// `lib/data/web/AGENTS.md`.
library;

import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:fs_shim/fs.dart";

import "../../core/log.dart";
import "ninep.dart";

/// What the guest may do with one path under the mount.
enum GuestAccess { hidden, readOnly, readWrite }

/// [segments] is a path relative to the mount's root.
typedef GuestPolicy = GuestAccess Function(List<String> segments);

/// What a command may reach of the data directory: every project's workspace
/// to work in, its skills and agents to run and read, and nothing that is the
/// app's own — chats, settings, secrets, memory — since a chat's log is not a
/// file the agent is ever handed, here or anywhere else.
GuestAccess entoliGuestAccess(List<String> segments) {
  if (segments.isEmpty) return GuestAccess.readOnly;
  if (segments.first != "projects") return GuestAccess.hidden;
  if (segments.length <= 2) return GuestAccess.readOnly;
  return switch (segments[2]) {
    "workspace" => GuestAccess.readWrite,
    "skills" || "skills-bundled" || "agents" => GuestAccess.readOnly,
    _ => GuestAccess.hidden,
  };
}

const _oTrunc = 0x200; // P9_DOTL_TRUNC, Linux's O_TRUNC
const _atRemoveDir = 0x200;
const _sIfDir = 0x4000;
const _sIfReg = 0x8000;
const _sIfLnk = 0xa000;
const _getattrBasic = 0x7ff;
const _setattrMode = 0x1;
const _setattrSize = 0x8;

class _P9Error implements Exception {
  const _P9Error(this.errno);
  final int errno;
}

class _Fid {
  _Fid(this.path);

  String path;

  /// Set by an open or a create; reads and writes go through [file], opened
  /// on first use and closed whenever its path is about to move.
  bool opened = false;
  bool writable = false;
  RandomAccessFile? file;

  /// A directory's entries as they were when the read started at offset 0,
  /// so a listing read in several replies is one listing.
  List<({String name, int kind})>? listing;
}

/// The permission bits the guest set, which IndexedDB has nowhere to keep:
/// without them a script made executable is not, and git sees every file it
/// wrote change mode. Kept beside the mount rather than in it, one JSON map,
/// written a moment after the last change.
class GuestModes {
  GuestModes(this.fs, this.path);

  final FileSystem fs;
  final String path;
  Map<String, int> _modes = {};
  Timer? _save;

  Future<void> load() async {
    try {
      final file = fs.file(path);
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _modes = json.map((k, v) => MapEntry(k, v as int));
    } catch (e) {
      logFailure("guest", "modes did not load", e);
    }
  }

  int? of(String p) => _modes[p];

  void set(String p, int mode) {
    _modes[p] = mode;
    _dirty();
  }

  void move(String from, String to) {
    final moved = <String, int>{};
    _modes.removeWhere((k, v) {
      if (k == from) {
        moved[to] = v;
      } else if (k.startsWith("$from/")) {
        moved["$to${k.substring(from.length)}"] = v;
      } else {
        return false;
      }
      return true;
    });
    if (moved.isEmpty) return;
    _modes.addAll(moved);
    _dirty();
  }

  void drop(String p) {
    final before = _modes.length;
    _modes.removeWhere((k, _) => k == p || k.startsWith("$p/"));
    if (_modes.length != before) _dirty();
  }

  void _dirty() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), flush);
  }

  Future<void> flush() async {
    _save?.cancel();
    _save = null;
    try {
      final temp = fs.file("$path.tmp");
      await temp.writeAsString(jsonEncode(_modes));
      await temp.rename(path);
    } catch (e) {
      logFailure("guest", "modes did not save", e);
    }
  }
}

/// One 9P2000.L server, for one guest. [handle] takes a request as the guest
/// sent it and answers with the reply, in order: the guest may send several
/// at once, and answering them one at a time is what keeps two writes to one
/// file from landing out of order in IndexedDB.
class GuestFileServer {
  GuestFileServer(this.fs,
      {required this.root, this.policy = entoliGuestAccess, this.modes});

  final FileSystem fs;

  /// The app path the mount's root stands for.
  final String root;
  final GuestPolicy policy;
  final GuestModes? modes;

  static const maxMsize = 128 * 1024;
  int _msize = maxMsize;

  final Map<int, _Fid> _fids = {};

  /// Inode numbers, by path, for as long as this server runs.
  final Map<String, int> _inodes = {};
  int _nextInode = 2;

  Future<void> _queue = Future.value();

  Future<Uint8List> handle(Uint8List request) {
    final reply = _queue.then((_) => _answer(request));
    _queue = reply.then((_) {}, onError: (_) {});
    return reply;
  }

  Future<Uint8List> _answer(Uint8List request) async {
    final r = P9Reader(request)..offset = 4;
    final type = r.u8();
    final tag = r.u16();
    final w = P9Writer();
    try {
      await _dispatch(type, r, w);
      return w.message(type + 1, tag);
    } on _P9Error catch (e) {
      return _error(tag, e.errno);
    } on FileSystemException catch (e) {
      return _error(tag, e.status ?? Errno.io);
    } catch (e) {
      logFailure("guest", "9p message $type failed", e);
      return _error(tag, Errno.io);
    }
  }

  Uint8List _error(int tag, int errno) =>
      (P9Writer()..u32(errno)).message(P9.lerror, tag);

  Future<void> _dispatch(int type, P9Reader r, P9Writer w) async {
    switch (type) {
      case P9.version:
        final msize = r.u32();
        final version = r.str();
        for (final fid in _fids.values) {
          await fid.file?.close();
        }
        _fids.clear();
        _msize = msize < maxMsize ? msize : maxMsize;
        w
          ..u32(_msize)
          ..str(version.startsWith("9P2000.L") ? "9P2000.L" : "unknown");
      case P9.attach:
        final fid = r.u32();
        _fids[fid] = _Fid(root);
        w.qid(await _qid(root));
      case P9.walk:
        await _walk(r, w);
      case P9.getattr:
        await _getattr(_fid(r.u32()).path, w);
      case P9.setattr:
        await _setattr(r);
      case P9.lopen:
        await _lopen(r, w);
      case P9.lcreate:
        await _lcreate(r, w);
      case P9.read:
        await _read(r, w);
      case P9.write:
        await _write(r, w);
      case P9.readdir:
        await _readdir(r, w);
      case P9.mkdir:
        final dir = _fid(r.u32()).path;
        final path = _child(dir, r.str());
        final mode = r.u32();
        _writable(path);
        if (await _kind(path) != FileSystemEntityType.notFound) {
          throw const _P9Error(Errno.exist);
        }
        await fs.directory(path).create();
        _keepMode(path, mode, 0x1ed);
        w.qid(await _qid(path));
      case P9.symlink:
        final dir = _fid(r.u32()).path;
        final path = _child(dir, r.str());
        final target = r.str();
        _writable(path);
        if (await _kind(path) != FileSystemEntityType.notFound) {
          throw const _P9Error(Errno.exist);
        }
        await fs.link(path).create(target);
        w.qid(await _qid(path));
      case P9.readlink:
        final path = _fid(r.u32()).path;
        if (await _kind(path) != FileSystemEntityType.link) {
          throw const _P9Error(Errno.inval);
        }
        w.str(await fs.link(path).target());
      case P9.renameat:
        final fromDir = _fid(r.u32()).path;
        final fromName = r.str();
        final toDir = _fid(r.u32()).path;
        await _rename(_child(fromDir, fromName), _child(toDir, r.str()));
      case P9.rename:
        final from = _fid(r.u32()).path;
        final toDir = _fid(r.u32()).path;
        await _rename(from, _child(toDir, r.str()));
      case P9.unlinkat:
        final dir = _fid(r.u32()).path;
        final path = _child(dir, r.str());
        await _unlink(path, directory: r.u32() & _atRemoveDir != 0);
      case P9.remove:
        final id = r.u32();
        final fid = _fid(id);
        final kind = await _kind(fid.path);
        await _unlink(fid.path, directory: kind == FileSystemEntityType.directory);
        await fid.file?.close();
        _fids.remove(id);
      case P9.clunk:
        final fid = _fids.remove(r.u32());
        await fid?.file?.close();
      case P9.fsync:
        await _fid(r.u32()).file?.flush();
      case P9.statfs:
        w
          ..u32(0x01021997) // V9FS_MAGIC
          ..u32(4096)
          ..u64(1 << 20)
          ..u64(1 << 19)
          ..u64(1 << 19)
          ..u64(1 << 20)
          ..u64(1 << 19)
          ..u64(0)
          ..u32(255);
      case P9.lock:
        // One guest, one writer: a lock is always granted.
        w.u8(0);
      case P9.getlock:
        r.u32();
        r.u8();
        final start = r.u64();
        final length = r.u64();
        final proc = r.u32();
        final client = r.str();
        w
          ..u8(2) // F_UNLCK: nothing holds it
          ..u64(start)
          ..u64(length)
          ..u32(proc)
          ..str(client);
      case P9.flush:
        break;
      case P9.xattrwalk || P9.xattrcreate:
        throw const _P9Error(Errno.opnotsupp);
      case P9.link || P9.mknod:
        throw const _P9Error(Errno.perm);
      default:
        throw const _P9Error(Errno.opnotsupp);
    }
  }

  _Fid _fid(int id) => _fids[id] ?? (throw const _P9Error(Errno.badf));

  List<String> _segments(String path) => path == root
      ? const []
      : path.substring(root.length + 1).split("/");

  GuestAccess _access(String path) => policy(_segments(path));

  void _writable(String path) {
    switch (_access(path)) {
      case GuestAccess.readWrite:
        return;
      case GuestAccess.readOnly:
        throw const _P9Error(Errno.rofs);
      case GuestAccess.hidden:
        throw const _P9Error(Errno.access);
    }
  }

  String _child(String dir, String name) {
    if (name.isEmpty || name == "." || name == ".." || name.contains("/")) {
      throw const _P9Error(Errno.inval);
    }
    return fs.path.join(dir, name);
  }

  Future<FileSystemEntityType> _kind(String path) async =>
      _access(path) == GuestAccess.hidden
          ? FileSystemEntityType.notFound
          : await fs.type(path, followLinks: false);

  int _inode(String path) =>
      path == root ? 1 : _inodes.putIfAbsent(path, () => _nextInode++);

  Future<Qid> _qid(String path, [FileSystemEntityType? known]) async {
    final kind = known ?? await _kind(path);
    return switch (kind) {
      FileSystemEntityType.directory => Qid(P9.qtDir, _inode(path)),
      FileSystemEntityType.link => Qid(P9.qtSymlink, _inode(path)),
      FileSystemEntityType.file => Qid(P9.qtFile, _inode(path)),
      _ => throw const _P9Error(Errno.noent),
    };
  }

  Future<void> _walk(P9Reader r, P9Writer w) async {
    final from = _fid(r.u32());
    final newFid = r.u32();
    final names = [for (var n = r.u16(); n > 0; n--) r.str()];
    var path = from.path;
    final qids = <Qid>[];
    for (final name in names) {
      final String next;
      if (name == "..") {
        next = path == root ? root : fs.path.dirname(path);
      } else if (name.isEmpty || name == "." || name.contains("/")) {
        break;
      } else {
        next = fs.path.join(path, name);
      }
      final kind = await _kind(next);
      if (kind == FileSystemEntityType.notFound) break;
      qids.add(await _qid(next, kind));
      path = next;
    }
    if (names.isNotEmpty && qids.isEmpty) throw const _P9Error(Errno.noent);
    if (qids.length == names.length) _fids[newFid] = _Fid(path);
    w.u16(qids.length);
    qids.forEach(w.qid);
  }

  int _perms(String path, FileSystemEntityType kind) {
    final stored = modes?.of(path);
    var perms = stored ??
        (kind == FileSystemEntityType.directory ? 0x1ed : 0x1a4); // 755, 644
    if (_access(path) != GuestAccess.readWrite) perms &= ~0x92; // no write bits
    return perms;
  }

  void _keepMode(String path, int mode, int byDefault) {
    final perms = mode & 0xfff;
    if (perms != byDefault) modes?.set(path, perms);
  }

  Future<void> _getattr(String path, P9Writer w) async {
    final kind = await _kind(path);
    final int size;
    final int mode;
    var modified = DateTime.fromMillisecondsSinceEpoch(0);
    switch (kind) {
      case FileSystemEntityType.directory:
        modified = (await fs.directory(path).stat()).modified;
        size = 4096;
        mode = _sIfDir | _perms(path, kind);
      case FileSystemEntityType.file:
        final stat = await fs.file(path).stat();
        modified = stat.modified;
        size = stat.size;
        mode = _sIfReg | _perms(path, kind);
      case FileSystemEntityType.link:
        size = utf8.encode(await fs.link(path).target()).length;
        mode = _sIfLnk | 0x1ff;
      default:
        throw const _P9Error(Errno.noent);
    }
    final ms = modified.millisecondsSinceEpoch;
    final sec = ms ~/ 1000;
    final nsec = (ms % 1000) * 1000000;
    w
      ..u64(_getattrBasic)
      ..qid(await _qid(path, kind))
      ..u32(mode)
      ..u32(0)
      ..u32(0)
      ..u64(kind == FileSystemEntityType.directory ? 2 : 1)
      ..u64(0)
      ..u64(size)
      ..u64(4096)
      ..u64((size + 511) ~/ 512);
    for (var i = 0; i < 3; i++) {
      w
        ..u64(sec)
        ..u64(nsec);
    }
    w
      ..u64(0) // btime
      ..u64(0)
      ..u64(0) // gen
      ..u64(0); // data_version
  }

  Future<void> _setattr(P9Reader r) async {
    final fid = _fid(r.u32());
    final valid = r.u32();
    final mode = r.u32();
    r.u32(); // uid
    r.u32(); // gid
    final size = r.u64();
    if (await _kind(fid.path) == FileSystemEntityType.notFound) {
      throw const _P9Error(Errno.noent);
    }
    _writable(fid.path);
    if (valid & _setattrSize != 0) {
      final open = fid.file;
      if (open != null && fid.writable) {
        await open.truncate(size);
      } else {
        final file = await fs.file(fid.path).open(mode: FileMode.append);
        await file.truncate(size);
        await file.close();
      }
    }
    if (valid & _setattrMode != 0) modes?.set(fid.path, mode & 0xfff);
    // Owners and times have nowhere to go: the guest is root, and IndexedDB
    // stamps a file when it is written.
  }

  Future<void> _lopen(P9Reader r, P9Writer w) async {
    final fid = _fid(r.u32());
    final flags = r.u32();
    final kind = await _kind(fid.path);
    if (kind == FileSystemEntityType.notFound) throw const _P9Error(Errno.noent);
    final writes = flags & 3 != 0 || flags & _oTrunc != 0;
    if (kind == FileSystemEntityType.directory) {
      if (writes) throw const _P9Error(Errno.isdir);
      fid.listing = null;
    } else if (writes) {
      _writable(fid.path);
    }
    fid
      ..opened = true
      ..writable = writes;
    // Through the handle: emptying the file with a write of nothing and then
    // writing through a handle loses the write in fs_shim's paging.
    if (writes && flags & _oTrunc != 0) await (await _open(fid)).truncate(0);
    w
      ..qid(await _qid(fid.path, kind))
      ..u32(0);
  }

  Future<void> _lcreate(P9Reader r, P9Writer w) async {
    final fid = _fid(r.u32());
    final path = _child(fid.path, r.str());
    r.u32(); // flags: a create is always a write
    final mode = r.u32();
    _writable(path);
    if (await _kind(path) != FileSystemEntityType.notFound) {
      throw const _P9Error(Errno.exist);
    }
    await fs.file(path).create();
    _keepMode(path, mode, 0x1a4);
    fid
      ..path = path
      ..opened = true
      ..writable = true;
    w
      ..qid(await _qid(path, FileSystemEntityType.file))
      ..u32(0);
  }

  Future<RandomAccessFile> _open(_Fid fid) async => fid.file ??= await fs
      .file(fid.path)
      .open(mode: fid.writable ? FileMode.append : FileMode.read);

  Future<void> _read(P9Reader r, P9Writer w) async {
    final fid = _fid(r.u32());
    final offset = r.u64();
    var count = r.u32();
    if (!fid.opened) throw const _P9Error(Errno.badf);
    if (count > _msize - 11) count = _msize - 11;
    final Uint8List data;
    if (fid.writable) {
      final file = await _open(fid);
      await file.setPosition(offset);
      data = await file.read(count);
    } else {
      // Read afresh each time rather than through a held handle, which keeps
      // the length the file had when it was opened: the app writes these
      // files between commands, and a guest holds a file open across them.
      final file = fs.file(fid.path);
      final builder = BytesBuilder(copy: false);
      final length = (await file.stat()).size;
      if (offset < length) {
        final end = offset + count < length ? offset + count : length;
        await file.openRead(offset, end).forEach(builder.add);
      }
      data = builder.takeBytes();
    }
    w
      ..u32(data.length)
      ..data(data);
  }

  Future<void> _write(P9Reader r, P9Writer w) async {
    final fid = _fid(r.u32());
    final offset = r.u64();
    final count = r.u32();
    final data = r.data(count);
    if (!fid.writable) throw const _P9Error(Errno.badf);
    final file = await _open(fid);
    await file.setPosition(offset);
    await file.writeFrom(data);
    w.u32(count);
  }

  Future<void> _readdir(P9Reader r, P9Writer w) async {
    final fid = _fid(r.u32());
    final offset = r.u64();
    final count = r.u32();
    if (offset == 0 || fid.listing == null) {
      final entries = <({String name, int kind})>[
        (name: ".", kind: P9.qtDir),
        (name: "..", kind: P9.qtDir),
      ];
      await for (final entity
          in fs.directory(fid.path).list(followLinks: false)) {
        final name = fs.path.basename(entity.path);
        if (_access(entity.path) == GuestAccess.hidden) continue;
        entries.add((
          name: name,
          kind: entity is Directory
              ? P9.qtDir
              : entity is Link
                  ? P9.qtSymlink
                  : P9.qtFile,
        ));
      }
      fid.listing = entries;
    }
    final entries = fid.listing!;
    final body = P9Writer();
    for (var i = offset; i < entries.length; i++) {
      final entry = entries[i];
      if (body.length + direntSize(entry.name) > count) break;
      final path = switch (entry.name) {
        "." => fid.path,
        ".." => fid.path == root ? root : fs.path.dirname(fid.path),
        _ => fs.path.join(fid.path, entry.name),
      };
      body
        ..qid(Qid(entry.kind, _inode(path)))
        ..u64(i + 1)
        ..u8(switch (entry.kind) {
          P9.qtDir => 4, // DT_DIR
          P9.qtSymlink => 10, // DT_LNK
          _ => 8, // DT_REG
        })
        ..str(entry.name);
    }
    final bytes = body.takeBytes();
    w
      ..u32(bytes.length)
      ..data(bytes);
  }

  /// Every open file at or under [path] is closed before it moves or goes:
  /// IndexedDB's handle is to the path it was opened at, and a write through
  /// it after a rename lands nowhere. The next read or write reopens it.
  Future<void> _release(String path) async {
    for (final fid in _fids.values) {
      if (fid.path == path || fid.path.startsWith("$path/")) {
        await fid.file?.close();
        fid.file = null;
      }
    }
  }

  Future<void> _rename(String from, String to) async {
    _writable(from);
    _writable(to);
    if (from == to) return;
    final kind = await _kind(from);
    if (kind == FileSystemEntityType.notFound) throw const _P9Error(Errno.noent);
    if (to.startsWith("$from/")) throw const _P9Error(Errno.inval);
    await _release(from);
    await _release(to);
    final existing = await _kind(to);
    if (existing == FileSystemEntityType.directory) {
      if (kind != FileSystemEntityType.directory) {
        throw const _P9Error(Errno.isdir);
      }
      await fs.directory(to).delete();
    } else if (existing != FileSystemEntityType.notFound) {
      if (kind == FileSystemEntityType.directory) {
        throw const _P9Error(Errno.notdir);
      }
      await _delete(to, existing);
    }
    switch (kind) {
      case FileSystemEntityType.directory:
        await fs.directory(from).rename(to);
      case FileSystemEntityType.link:
        await fs.link(from).rename(to);
      default:
        await fs.file(from).rename(to);
    }
    final moved = <String, int>{};
    _inodes.removeWhere((k, v) {
      if (k == from) {
        moved[to] = v;
      } else if (k.startsWith("$from/")) {
        moved["$to${k.substring(from.length)}"] = v;
      } else {
        return false;
      }
      return true;
    });
    _inodes.addAll(moved);
    for (final fid in _fids.values) {
      if (fid.path == from) {
        fid.path = to;
      } else if (fid.path.startsWith("$from/")) {
        fid.path = "$to${fid.path.substring(from.length)}";
      }
    }
    modes?.drop(to);
    modes?.move(from, to);
  }

  Future<void> _unlink(String path, {required bool directory}) async {
    _writable(path);
    final kind = await _kind(path);
    if (kind == FileSystemEntityType.notFound) throw const _P9Error(Errno.noent);
    if (directory && kind != FileSystemEntityType.directory) {
      throw const _P9Error(Errno.notdir);
    }
    if (!directory && kind == FileSystemEntityType.directory) {
      throw const _P9Error(Errno.isdir);
    }
    await _release(path);
    await _delete(path, kind);
    _inodes.remove(path);
    modes?.drop(path);
  }

  Future<void> _delete(String path, FileSystemEntityType kind) =>
      switch (kind) {
        FileSystemEntityType.directory => fs.directory(path).delete(),
        FileSystemEntityType.link => fs.link(path).delete(),
        _ => fs.file(path).delete(),
      };
}
