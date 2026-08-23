import "dart:typed_data";

/// RAM-only cache of mirrored attachments, bounded by bytes rather than
/// entries — an image-heavy conversation is where the megabytes are.
///
/// Mirrored bytes have no disk behind them (`resources/` lives on the home
/// device), so without this every scroll past an image was a round trip.
/// Least-recently-used by touch on get; the bound evicts oldest-first.
class SyncByteCache {
  static const _capacity = 64 * 1024 * 1024;

  final _entries = <String, Uint8List>{};
  var _held = 0;

  Uint8List? get(String chatId, String resource) {
    final key = "$chatId/$resource";
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  void put(String chatId, String resource, Uint8List bytes) {
    final key = "$chatId/$resource";
    final previous = _entries.remove(key);
    if (previous != null) _held -= previous.length;
    _entries[key] = bytes;
    _held += bytes.length;
    while (_held > _capacity && _entries.isNotEmpty) {
      final evictedKey = _entries.keys.first;
      _held -= _entries.remove(evictedKey)!.length;
    }
  }

  /// A chat gone from the mirrors takes its bytes with it.
  void drop(String chatId) {
    final prefix = "$chatId/";
    for (final key in _entries.keys
        .where((k) => k.startsWith(prefix))
        .toList()) {
      _held -= _entries.remove(key)!.length;
    }
  }

  void dispose() {
    _entries.clear();
    _held = 0;
  }
}
