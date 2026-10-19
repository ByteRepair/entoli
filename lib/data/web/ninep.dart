/// 9P2000.L on the wire: the message numbers and the little-endian fields the
/// guest kernel's 9p client speaks. Only what [GuestFileServer] answers is
/// named here.
library;

import "dart:convert";
import "dart:typed_data";

abstract final class P9 {
  static const lerror = 7;
  static const statfs = 8;
  static const lopen = 12;
  static const lcreate = 14;
  static const symlink = 16;
  static const mknod = 18;
  static const rename = 20;
  static const readlink = 22;
  static const getattr = 24;
  static const setattr = 26;
  static const xattrwalk = 30;
  static const xattrcreate = 32;
  static const readdir = 40;
  static const fsync = 50;
  static const lock = 52;
  static const getlock = 54;
  static const link = 70;
  static const mkdir = 72;
  static const renameat = 74;
  static const unlinkat = 76;
  static const version = 100;
  static const auth = 102;
  static const attach = 104;
  static const flush = 108;
  static const walk = 110;
  static const read = 116;
  static const write = 118;
  static const clunk = 120;
  static const remove = 122;

  static const qtDir = 0x80;
  static const qtSymlink = 0x02;
  static const qtFile = 0x00;

  static const noFid = 0xffffffff;
}

/// The errno values a reply carries, Linux's numbering.
abstract final class Errno {
  static const perm = 1;
  static const noent = 2;
  static const io = 5;
  static const badf = 9;
  static const access = 13;
  static const exist = 17;
  static const notdir = 20;
  static const isdir = 21;
  static const inval = 22;
  static const rofs = 30;
  static const nametoolong = 36;
  static const nosys = 38;
  static const notempty = 39;
  static const opnotsupp = 95;
}

/// The identity of a file to the guest: what kind it is, and a number that
/// stays its own for as long as the server runs.
class Qid {
  const Qid(this.type, this.path, {this.version = 0});
  final int type;
  final int version;
  final int path;
}

class P9Reader {
  P9Reader(this.bytes) : _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;
  int offset = 0;

  int u8() => _data.getUint8(offset++);

  int u16() {
    final v = _data.getUint16(offset, Endian.little);
    offset += 2;
    return v;
  }

  int u32() {
    final v = _data.getUint32(offset, Endian.little);
    offset += 4;
    return v;
  }

  // Two halves: a JavaScript number cannot hold every u64, and no offset or
  // size this server sees comes near 2^53.
  int u64() {
    final low = u32();
    final high = u32();
    return high * 0x100000000 + low;
  }

  String str() {
    final length = u16();
    final s = utf8.decode(bytes.sublist(offset, offset + length),
        allowMalformed: true);
    offset += length;
    return s;
  }

  Uint8List data(int length) {
    final d = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return d;
  }
}

class P9Writer {
  final _out = BytesBuilder(copy: false);
  final _scratch = ByteData(8);

  void u8(int v) => _out.addByte(v & 0xff);

  void u16(int v) {
    _scratch.setUint16(0, v, Endian.little);
    _out.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 2)));
  }

  void u32(int v) {
    _scratch.setUint32(0, v & 0xffffffff, Endian.little);
    _out.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
  }

  void u64(int v) {
    u32(v % 0x100000000);
    u32(v ~/ 0x100000000);
  }

  void str(String s) {
    final b = utf8.encode(s);
    u16(b.length);
    _out.add(b);
  }

  void qid(Qid q) {
    u8(q.type);
    u32(q.version);
    u64(q.path);
  }

  void data(List<int> d) => _out.add(d);

  int get length => _out.length;

  Uint8List takeBytes() => _out.takeBytes();

  /// The whole message: size, type and tag over what was written.
  Uint8List message(int type, int tag) {
    final body = _out.takeBytes();
    final head = ByteData(7)
      ..setUint32(0, body.length + 7, Endian.little)
      ..setUint8(4, type)
      ..setUint16(5, tag, Endian.little);
    return Uint8List(body.length + 7)
      ..setAll(0, head.buffer.asUint8List())
      ..setAll(7, body);
  }
}

/// Size of a directory entry in an Rreaddir: qid, offset, type, name.
int direntSize(String name) => 13 + 8 + 1 + 2 + utf8.encode(name).length;
