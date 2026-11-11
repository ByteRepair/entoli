import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/agent_face.dart";
import "../../domain/bot_avatar/pose.dart";
import "../../providers.dart";
import "../bot_avatar/bot_avatar_view.dart";

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
