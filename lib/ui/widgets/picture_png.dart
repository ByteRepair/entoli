import "dart:typed_data";
import "dart:ui" as ui;

/// What [draw] paints into a [px] square, as PNG bytes: for a picture made
/// for a surface Flutter does not draw, such as the native shell's menu.
Future<Uint8List?> pngOf(int px, void Function(ui.Canvas canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(ui.Canvas(recorder));
  final image = await recorder.endRecording().toImage(px, px);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
