import "dart:typed_data";

import "package:agent_chat/data/voice/pcm.dart";
import "package:flutter_test/flutter_test.dart";

/// [samples] as little-endian PCM16, in a buffer with [before] bytes of
/// something else in front of it — which is what a platform channel hands over.
Uint8List _pcm(List<int> samples, {int before = 0}) {
  final buffer = ByteData(before + samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    buffer.setInt16(before + i * 2, samples[i], Endian.little);
  }
  return Uint8List.sublistView(buffer, before);
}

void main() {
  test("reads samples from a view at an odd offset", () {
    // Five bytes is what Android's codec leaves in front of a byte array, and
    // an odd offset is one `asInt16List` throws on outright.
    final read = Pcm16Reader().read(_pcm([0, 16384, -16384, 32767], before: 5));
    expect(read, hasLength(4));
    expect(read[0], 0);
    expect(read[1], closeTo(0.5, 0.001));
    expect(read[2], closeTo(-0.5, 0.001));
    expect(read[3], closeTo(1.0, 0.001));
  });

  test("carries a sample split across two chunks", () {
    final whole = _pcm([1000, -2000, 3000], before: 5);
    final reader = Pcm16Reader();
    // Cut mid-sample, which is where a byte would be dropped and every sample
    // after it shifted.
    expect(reader.read(Uint8List.sublistView(whole, 0, 3)), hasLength(1));
    expect(
      reader.read(Uint8List.sublistView(whole, 3)).map((v) => (v * 32768).round()),
      [-2000, 3000],
    );
  });

  test("an empty chunk keeps what was carried", () {
    final whole = _pcm([-1234], before: 5);
    final reader = Pcm16Reader();
    expect(reader.read(Uint8List.sublistView(whole, 0, 1)), isEmpty);
    expect(reader.read(Uint8List(0)), isEmpty);
    expect(
      reader.read(Uint8List.sublistView(whole, 1)).map((v) => (v * 32768).round()),
      [-1234],
    );
  });
}
