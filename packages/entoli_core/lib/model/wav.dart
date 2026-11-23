import "dart:typed_data";

/// A 16-bit mono WAV of [samples], which is what a player takes and what the
/// speech model does not produce. Written here rather than through sherpa's own
/// helper so that the main isolate, where playback happens, needs nothing of
/// sherpa at all.
Uint8List wavOf(Float32List samples, int sampleRate) {
  final data = _withHeader(samples.length * 2, sampleRate);
  for (var i = 0; i < samples.length; i++) {
    // Clamped rather than wrapped: a sample past full scale that wraps is a
    // click, and models do overshoot.
    final value = (samples[i] * 32767).round().clamp(-32768, 32767);
    data.setInt16(_headerBytes + i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// A mono WAV of [pcm], 16-bit little-endian samples already: what a provider
/// that answers in raw PCM sends.
Uint8List wavOfPcm16(Uint8List pcm, int sampleRate) =>
    _withHeader(pcm.length, sampleRate).buffer.asUint8List()
      ..setRange(_headerBytes, _headerBytes + pcm.length, pcm);

const _headerBytes = 44;

/// A WAV's whole buffer, its header written and [dataBytes] of room after it.
ByteData _withHeader(int dataBytes, int sampleRate) {
  final data = ByteData(_headerBytes + dataBytes);
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
  u32(36 + dataBytes);
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
  u32(dataBytes);
  return data;
}
