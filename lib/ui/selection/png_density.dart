import "dart:typed_data";

import "package:archive/archive.dart" show getCrc32;

/// [png] saying it holds [ratio] pixels to the point. A paste target reading
/// RTF — Pages, TextEdit — sizes a picture by its density and not by the
/// HTML's width and height, and a PNG that says nothing is 72 dots to the
/// inch: a formula drawn at three times its size pasted three times too big.
/// The density is a `pHYs` chunk, placed after the header as the format asks.
Uint8List withDensity(Uint8List png, double ratio) {
  const signature = 8, header = 8 + 13 + 4;
  final perMetre = (72 * ratio / 0.0254).round();
  final chunk = ByteData(4 + 4 + 9 + 4)
    ..setUint32(0, 9)
    ..setUint8(4, 0x70) // p
    ..setUint8(5, 0x48) // H
    ..setUint8(6, 0x59) // Y
    ..setUint8(7, 0x73) // s
    ..setUint32(8, perMetre)
    ..setUint32(12, perMetre)
    ..setUint8(16, 1); // per metre
  final bytes = chunk.buffer.asUint8List();
  chunk.setUint32(17, getCrc32(bytes.sublist(4, 17)));
  return Uint8List.fromList([
    ...png.sublist(0, signature + header),
    ...bytes,
    ...png.sublist(signature + header),
  ]);
}
