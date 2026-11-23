import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "package:entoli_chat/ui/widgets/agent_picture.dart";

export "package:entoli_chat/ui/widgets/agent_picture.dart";

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
