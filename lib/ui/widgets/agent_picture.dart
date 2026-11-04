import "dart:math" as math;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/agent_face.dart";
import "../../domain/bot_avatar/pose.dart";
import "../../providers.dart";
import "../bot_avatar/bot_avatar_view.dart";
import "picture_png.dart";

/// An agent's face from one already in hand: its photo, circular; its Bot
/// Avatar, drawn in place of the circle; or the person mark where it has
/// neither. The leaf of [AgentPicture], kept separate so a caller holding an
/// edited face can show it: the provider-backed copy reads what is on disk,
/// and an editor shows what it is about to write.
///
/// A Bot Avatar is a still unless [animate] — a list of agents would
/// otherwise run a ticker a row. Live, it moves in [mood], looks toward the
/// pointer and glances at a touch, and where [reactToTap] a tap makes it
/// happy for a while.
class AgentPictureImage extends StatelessWidget {
  const AgentPictureImage({
    super.key,
    required this.face,
    this.size = 36,
    this.animate = false,
    this.mood = BotMood.idle,
    this.reactToTap = false,
  });

  final AgentFace? face;
  final double size;
  final bool animate;
  final BotMood mood;
  final bool reactToTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (face) {
      AgentBot(:final spec) => BotAvatarView(
        spec: spec,
        size: size,
        animate: animate,
        mood: mood,
        reactToTap: reactToTap,
        semanticLabel: "",
      ),
      final face => Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
        child: face is AgentPhoto
            ? Image.memory(
                face.bytes,
                // The decode target the picture is drawn at: a photograph in
                // the agents directory would otherwise decode tens of MB to
                // fill three dozen logical pixels — and a list row per agent.
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                fit: BoxFit.cover,
              )
            : Icon(
                Icons.person,
                size: size * 0.7,
                color: theme.colorScheme.onSurfaceVariant,
              ),
      ),
    };
  }
}

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

/// An agent's face as the project shows it: the `<name>.avatar.json` or
/// `<name>.png` beside the agent's `.md`, resolved over the library's tier
/// walk — a project's own answers over an inherited one — or the fallback
/// where no tier holds one. The agents list's leading element and the
/// context page's header are the callers.
class AgentPicture extends ConsumerWidget {
  const AgentPicture({
    super.key,
    required this.name,
    this.project,
    this.size = 36,
    this.animate = false,
    this.reactToTap = false,
  });

  final String name;
  final String? project;
  final double size;
  final bool animate;
  final bool reactToTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final face = ref
        .watch(agentPictureProvider((project: project, name: name)))
        .value;
    return AgentPictureImage(
      face: face,
      size: size,
      animate: animate,
      reactToTap: reactToTap,
    );
  }
}
