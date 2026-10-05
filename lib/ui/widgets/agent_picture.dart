import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";

/// An agent's picture, circular, from bytes already in hand — or the person
/// mark where there are none. The leaf of [AgentPicture], kept separate so a
/// caller holding edited bytes can show them: the provider-backed copy reads
/// what is on disk, and an editor shows what it is about to write.
class AgentPictureImage extends StatelessWidget {
  const AgentPictureImage({super.key, required this.bytes, this.size = 36});

  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: bytes != null
          ? Image.memory(
              bytes!,
              // The decode target the picture is drawn at: a photograph in
              // the agents directory would otherwise decode tens of MB to
              // fill three dozen logical pixels — and a list row per agent.
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              fit: BoxFit.cover,
            )
          : Icon(
              Icons.person,
              size: size * 0.7,
              color: theme.colorScheme.onSurfaceVariant,
            ),
    );
  }
}

/// An agent's profile picture as the project shows it: the `<name>.png`
/// beside the agent's `.md`, resolved over the library's tier walk — a
/// project's own answers over an inherited one — or the fallback where no
/// tier holds one. The agents list's leading element and the Omada reply's
/// avatar are the callers.
class AgentPicture extends ConsumerWidget {
  const AgentPicture({super.key, required this.name, this.project, this.size = 36});

  final String name;
  final String? project;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(
      agentPictureProvider((project: project, name: name)),
    ).value;
    return AgentPictureImage(bytes: bytes, size: size);
  }
}