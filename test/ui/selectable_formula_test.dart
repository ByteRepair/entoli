import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/selection/selectable_formula.dart";

// A formula pastes as a PNG drawn at three times its size; a target that
// sizes a picture by its density — Pages, TextEdit — has to be told so, or
// it pastes three times too big.
void main() {
  test("a formula's picture says it is three pixels to the point", () {
    // A PNG's signature and header chunk, then the rest of a file.
    final png = Uint8List.fromList([
      ...List.filled(8 + 8 + 13 + 4, 1),
      ...List.filled(12, 2),
    ]);

    final stamped = withDensity(png, 3);

    // After the header, before everything else: the chunk's length, its
    // type, the density twice, the unit, and its checksum — the values
    // Python's own `zlib.crc32` gives for the same bytes.
    expect(stamped.sublist(0, 33), png.sublist(0, 33));
    final chunk = ByteData.sublistView(stamped, 33, 33 + 21);
    expect(chunk.getUint32(0), 9);
    expect(String.fromCharCodes(stamped.sublist(37, 41)), "pHYs");
    expect(chunk.getUint32(8), 8504);
    expect(chunk.getUint32(12), 8504);
    expect(chunk.getUint8(16), 1);
    expect(chunk.getUint32(17), 0x45963160);
    expect(stamped.sublist(54), png.sublist(33));
  });
}
