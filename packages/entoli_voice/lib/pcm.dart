import "package:flutter/foundation.dart";

/// The microphone's bytes, as samples between -1 and 1.
///
/// Its own class, and not a line inside the session, because both things it
/// gets right are invisible: what arrives is a *view* into the buffer the
/// platform channel decoded into, and one chunk does not have to end on a
/// sample. Neither is visible in a debugger and both are silent when wrong.
class Pcm16Reader {
  /// The low byte of a sample the last chunk ended part-way through.
  int? _carry;

  Float32List read(Uint8List bytes) {
    if (bytes.isEmpty) return _none;
    // Through a `ByteData` rather than `asInt16List`: the view starts at
    // whatever offset the codec left, which on Android is 5, and an odd offset
    // is one `asInt16List` refuses outright.
    final data = ByteData.sublistView(bytes);
    // -1 reads the sample split across the end of the last chunk and the start
    // of this one. Carried rather than dropped: a byte lost shifts every sample
    // after it by one, and the rest of the session is noise.
    final from = _carry == null ? 0 : -1;
    final samples = Float32List((data.lengthInBytes - from) ~/ 2);
    var at = from;
    for (var i = 0; i < samples.length; i++, at += 2) {
      final raw = at < 0
          ? _joined(data.getUint8(0))
          : data.getInt16(at, Endian.little);
      samples[i] = raw / 32768.0;
    }
    _carry = at < data.lengthInBytes ? data.getUint8(at) : null;
    return samples;
  }

  /// The carried low byte and the high byte that finishes it, little-endian —
  /// which is what PCM is, whatever the host happens to be.
  int _joined(int high) {
    final raw = _carry! | (high << 8);
    return raw >= 0x8000 ? raw - 0x10000 : raw;
  }

  static final _none = Float32List(0);
}
