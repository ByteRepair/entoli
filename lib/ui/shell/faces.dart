import "dart:math" as math;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/agent_face.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../domain/bot_avatar/frame.dart";
import "../../providers.dart";
import "../bot_avatar/bot_avatar_view.dart";

/// The agents' faces as pictures for the native shell's composer menu, which
/// Flutter does not draw: drawn by Flutter's canvas into PNG bytes.

/// [face] as PNG bytes, [size] logical pixels square at [pixelRatio], drawn as
/// [AgentPictureImage] draws it still — a photo in a circle, a Bot Avatar
/// with its [outline] — or null where there is no face to draw. For a
/// surface Flutter does not draw: the native shell's composer menu.
Future<Uint8List?> agentFacePng(
  AgentFace? face, {
  required double size,
  required double pixelRatio,
  required Color outline,
}) async {
  switch (face) {
    case AgentBot(:final spec):
      return botAvatarPng(
        spec,
        size: size,
        pixelRatio: pixelRatio,
        outline: outline,
      );
    case AgentPhoto(:final bytes):
      final px = (size * pixelRatio).ceil();
      // Decoded with its shorter side at the size drawn, and its middle
      // square taken, as the row's `BoxFit.cover` does.
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: (w, h) => w < h
            ? ui.TargetImageSize(width: px)
            : ui.TargetImageSize(height: px),
      );
      final photo = (await codec.getNextFrame()).image;
      codec.dispose();
      try {
        final side = math.min(photo.width, photo.height).toDouble();
        final box = Offset.zero & Size.square(px.toDouble());
        return await pngOf(
          px,
          (canvas) => canvas
            ..clipPath(Path()..addOval(box))
            ..drawImageRect(
              photo,
              Rect.fromCenter(
                center: Offset(photo.width / 2, photo.height / 2),
                width: side,
                height: side,
              ),
              box,
              Paint()..filterQuality = FilterQuality.medium,
            ),
        );
      } finally {
        photo.dispose();
      }
    default:
      return null;
  }
}

/// An agent's face in a project as PNG bytes, by [agentFacePng]: held while
/// a native composer menu could offer the agent, so the rows have their
/// pictures by the time an `@` is typed.
final agentFacePngProvider = FutureProvider.autoDispose
    .family<
      Uint8List?,
      ({
        String? project,
        String name,
        double size,
        double pixelRatio,
        Color outline,
      })
    >((ref, key) async {
      final face = await ref.watch(
        agentPictureProvider((project: key.project, name: key.name)).future,
      );
      return agentFacePng(
        face,
        size: key.size,
        pixelRatio: key.pixelRatio,
        outline: key.outline,
      );
    });

/// One still of [spec] as PNG bytes, [size] logical pixels square at
/// [pixelRatio], in the pose [BotAvatarView] holds as a still: for a surface
/// Flutter does not draw, the native shell's composer menu.
Future<Uint8List?> botAvatarPng(
  BotAvatarSpec spec, {
  required double size,
  required double pixelRatio,
  required Color outline,
}) async {
  final frame = ValueNotifier(
    PreparedBotAvatar.of(
      spec.definition,
    ).frame(reducedMotion: true, gaze: stillGaze),
  );
  try {
    return await pngOf(
      (size * pixelRatio).ceil(),
      (canvas) => BotAvatarPainter(
        frame: frame,
        colour: Color(0xff000000 | spec.colour),
        outline: outline,
      ).paint(canvas..scale(pixelRatio), Size.square(size)),
    );
  } finally {
    frame.dispose();
  }
}

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
