import "dart:typed_data";

/// A 16-bit mono WAV of [samples], which is what a player takes and what the
/// speech model does not produce. Written here rather than through sherpa's own
/// helper so that the main isolate, where playback happens, needs nothing of
/// sherpa at all.
Uint8List wavOf(Float32List samples, int sampleRate) {
  const headerBytes = 44;
  final data = ByteData(headerBytes + samples.length * 2);
  var at = 0;
  void ascii(String s) {
    for (final c in s.codeUnits) {
      data.setUint8(at++, c);
    }
  }

  void u32(int v) {
    data.setUint32(at, v, Endian.little);
    at += 4;
  }

  void u16(int v) {
    data.setUint16(at, v, Endian.little);
    at += 2;
  }

  ascii("RIFF");
  u32(36 + samples.length * 2);
  ascii("WAVE");
  ascii("fmt ");
  u32(16); // PCM header length
  u16(1); // PCM, uncompressed
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // bytes per second
  u16(2); // bytes per frame
  u16(16); // bits per sample
  ascii("data");
  u32(samples.length * 2);
  for (final sample in samples) {
    // Clamped rather than wrapped: a sample past full scale that wraps is a
    // click, and models do overshoot.
    final value = (sample * 32767).round().clamp(-32768, 32767);
    data.setInt16(at, value, Endian.little);
    at += 2;
  }
  return data.buffer.asUint8List();
}
