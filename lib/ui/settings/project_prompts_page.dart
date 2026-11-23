import "package:flutter/material.dart";

import "../../app/settings/scope.dart";
import "package:entoli_chat/domain/models.dart";
import "package:entoli_chat/domain/project.dart" show projectLabel;
import "package:entoli_chat/ui/widgets/page_bar.dart";
import "agents_settings.dart";
import "skills_settings.dart";

/// A project's own skills or agents as a page of their own. The list owns
/// the scroll, so its footer stays pinned to the bottom.
class ProjectPromptsPage extends StatelessWidget {
  const ProjectPromptsPage({super.key, required this.kind, required this.at});

  final CompletionKind kind;
  final ProjectAddress at;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: PageBar(title: kind.label, subtitle: projectLabel(at.project)),
    body: SafeArea(
      child: switch (kind) {
        CompletionKind.skill => SkillsSettings(at: at),
        CompletionKind.agent => AgentsSettings(at: at),
      },
    ),
  );
}

Future<void> openProjectPrompts(
  BuildContext context,
  CompletionKind kind,
  ProjectAddress at,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ProjectPromptsPage(kind: kind, at: at),
  ),
);
