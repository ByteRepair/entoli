import "dart:convert";
import "dart:io";
import "dart:typed_data";

/// What a GGUF says about itself that the server's sizing needs, read off its
/// header.
class GgufFacts {
  const GgufFacts({
    required this.name,
    required this.quantisation,
    required this.contextLength,
    required this.kvBytesPerToken,
  });

  /// `general.name`, where the file has one.
  final String? name;
  final String quantisation;
  final int contextLength;
  final int kvBytesPerToken;
}

/// Reads [path]'s header. Throws a [FormatException] for a file that is not a
/// GGUF or does not say what a model's context costs.
///
/// The cost is K and V for every layer, f16: `head_count_kv` is one number for
/// every layer, or a list where a layer with none — a convolution, in a hybrid
/// such as LFM3 — holds no cache.
GgufFacts readGgufFacts(String path) {
  final file = File(path).openSync();
  try {
    final meta = _Header(file).metadata();
    final arch = meta["general.architecture"];
    if (arch is! String) throw const FormatException("no architecture");
    int? number(String key) => switch (meta["$arch.$key"]) {
      final int n => n,
      _ => null,
    };
    final layers = number("block_count");
    final context = number("context_length");
    final heads = number("attention.head_count");
    final width = number("embedding_length");
    final key =
        number("attention.key_length") ??
        (heads != null && width != null ? width ~/ heads : null);
    final value = number("attention.value_length") ?? key;
    final kvHeads = switch (meta["$arch.attention.head_count_kv"]) {
      final int n when layers != null => n * layers,
      final List<Object?> perLayer => perLayer.whereType<int>().fold(
        0,
        (a, n) => a + n,
      ),
      _ => heads != null && layers != null ? heads * layers : null,
    };
    if (context == null ||
        key == null ||
        value == null ||
        kvHeads == null ||
        kvHeads == 0) {
      throw FormatException("$arch does not say what its context costs");
    }
    final type = meta["general.file_type"];
    return GgufFacts(
      name: meta["general.name"] as String?,
      quantisation: type is int ? _fileTypes[type] ?? "type $type" : "unknown",
      contextLength: context,
      kvBytesPerToken: kvHeads * (key + value) * 2,
    );
  } finally {
    file.closeSync();
  }
}

/// llama.cpp's `llama_ftype`, for the ones a model is published as.
const _fileTypes = {
  0: "F32",
  1: "F16",
  2: "Q4_0",
  3: "Q4_1",
  7: "Q8_0",
  8: "Q5_0",
  9: "Q5_1",
  10: "Q2_K",
  11: "Q3_K_S",
  12: "Q3_K_M",
  13: "Q3_K_L",
  14: "Q4_K_S",
  15: "Q4_K_M",
  16: "Q5_K_S",
  17: "Q5_K_M",
  18: "Q6_K",
  25: "IQ4_NL",
  30: "IQ4_XS",
  32: "BF16",
  38: "MXFP4",
};

/// The key–value section, read in blocks: a vocabulary is hundreds of
/// thousands of strings, skipped rather than decoded.
class _Header {
  _Header(this._file);

  final RandomAccessFile _file;
  var _buffer = Uint8List(0);
  var _at = 0;

  Map<String, Object?> metadata() {
    if (ascii.decode(_bytes(4), allowInvalid: true) != "GGUF") {
      throw const FormatException("not a GGUF");
    }
    final version = _u32();
    if (version < 2) throw FormatException("GGUF version $version");
    _u64(); // tensors
    final count = _u64();
    return {for (var i = 0; i < count; i++) _string(): _value(_u32())};
  }

  Object? _value(int type) => switch (type) {
    0 => _bytes(1)[0],
    1 => _view(1).getInt8(0),
    2 => _view(2).getUint16(0, Endian.little),
    3 => _view(2).getInt16(0, Endian.little),
    4 => _u32(),
    5 => _view(4).getInt32(0, Endian.little),
    6 => _view(4).getFloat32(0, Endian.little),
    7 => _bytes(1)[0] != 0,
    8 => _string(),
    9 => _array(),
    10 => _u64(),
    11 => _view(8).getInt64(0, Endian.little),
    12 => _view(8).getFloat64(0, Endian.little),
    _ => throw FormatException("value type $type"),
  };

  /// Kept only where it is short enough to be a per-layer list.
  Object? _array() {
    final type = _u32();
    final length = _u64();
    if (length > 1024) {
      for (var i = 0; i < length; i++) {
        _skip(type);
      }
      return null;
    }
    return [for (var i = 0; i < length; i++) _value(type)];
  }

  void _skip(int type) {
    const widths = {
      0: 1,
      1: 1,
      2: 2,
      3: 2,
      4: 4,
      5: 4,
      6: 4,
      7: 1,
      10: 8,
      11: 8,
      12: 8,
    };
    if (type == 8) {
      _bytes(_u64());
    } else if (widths[type] case final width?) {
      _bytes(width);
    } else {
      _value(type);
    }
  }

  String _string() => utf8.decode(_bytes(_u64()), allowMalformed: true);
  int _u32() => _view(4).getUint32(0, Endian.little);
  int _u64() => _view(8).getUint64(0, Endian.little);
  ByteData _view(int n) => ByteData.sublistView(_bytes(n));

  Uint8List _bytes(int n) {
    if (_at + n > _buffer.length) {
      final rest = _buffer.sublist(_at);
      final more = _file.readSync(n > _block ? n : _block);
      if (rest.length + more.length < n) {
        throw const FormatException("truncated");
      }
      _buffer = Uint8List.fromList([...rest, ...more]);
      _at = 0;
    }
    final out = Uint8List.sublistView(_buffer, _at, _at + n);
    _at += n;
    return out;
  }

  static const _block = 1 << 20;
}
