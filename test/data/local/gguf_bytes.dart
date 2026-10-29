import "dart:convert";
import "dart:typed_data";

/// A GGUF header with [metadata] and no tensors, which is all `readGgufFacts`
/// reads. Ints are written as uint32, strings as strings, lists of ints as
/// int32 arrays, and lists of strings as string arrays.
List<int> ggufBytes(Map<String, Object> metadata) {
  final out = BytesBuilder();
  void u32(int n) => out.add((ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List());
  void u64(int n) => out.add((ByteData(8)..setUint64(0, n, Endian.little)).buffer.asUint8List());
  void string(String s) {
    final bytes = utf8.encode(s);
    u64(bytes.length);
    out.add(bytes);
  }

  out.add(ascii.encode("GGUF"));
  u32(3);
  u64(0);
  u64(metadata.length);
  for (final MapEntry(:key, :value) in metadata.entries) {
    string(key);
    switch (value) {
      case final int n:
        u32(4);
        u32(n);
      case final String s:
        u32(8);
        string(s);
      case final List<int> list:
        u32(9);
        u32(5);
        u64(list.length);
        for (final n in list) {
          out.add((ByteData(4)..setInt32(0, n, Endian.little)).buffer.asUint8List());
        }
      case final List<String> list:
        u32(9);
        u32(8);
        u64(list.length);
        list.forEach(string);
      default:
        throw ArgumentError(value);
    }
  }
  return out.toBytes();
}

/// A small model's header: four layers of two KV heads, 64 wide, Q4_0.
List<int> tinyModel({String name = "Tiny 1B"}) => ggufBytes({
      "general.architecture": "tiny",
      "general.name": name,
      "general.file_type": 2,
      "tiny.block_count": 4,
      "tiny.context_length": 32768,
      "tiny.attention.head_count": 8,
      "tiny.attention.head_count_kv": 2,
      "tiny.attention.key_length": 64,
      "tiny.attention.value_length": 64,
    });
