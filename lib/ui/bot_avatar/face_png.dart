import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/widgets.dart";

import "../../domain/agent_face.dart";
import "../../domain/bot_avatar/frame.dart";
import "bot_avatar_view.dart";

/// [face] as a picture another frontend can show: a photo as it is, a Bot
/// Avatar painted at rest into a [size]-pixel square. Null for no face.
Future<Uint8List?> agentFacePng(AgentFace? face, {int size = 128}) async {
  switch (face) {
    case AgentPhoto(:final bytes):
      return bytes;
    case AgentBot(:final spec):
      final frame = PreparedBotAvatar.of(
        spec.definition,
      ).frame(reducedMotion: true, gaze: stillGaze);
      final recorder = ui.PictureRecorder();
      BotAvatarPainter(
        frame: ValueNotifier(frame),
        colour: Color(0xff000000 | spec.colour),
      ).paint(Canvas(recorder), Size.square(size.toDouble()));
      final image = await recorder.endRecording().toImage(size, size);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    case null:
      return null;
  }
}
