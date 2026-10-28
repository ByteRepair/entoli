import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart";
import "../../../providers.dart";
import "../../skills/skill_install_preview.dart";
import "activity.dart";

/// An `artifact` call, once it is history: a prominent card the user taps to
/// open the page the model rendered. Output the user came for rather than
/// background activity, so a card and not a label, and important. The
/// artifact's identity is in its part, not the tool call.
class ArtifactActivity extends Activity {
  const ArtifactActivity();

  @override
  bool important(Run run) => true;

  @override
  Widget build(Run run) => _ArtifactCard(chatId: run.chatId, part: run.part! as ArtifactPart);
}

class _ArtifactCard extends ConsumerWidget {
  const _ArtifactCard({required this.chatId, required this.part});

  final String chatId;
  final ArtifactPart part;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final ArtifactPart(:artifactId, :entryFile, :title) = part;
    return _OutputCard(
      kind: "Artifact",
      label: title.isEmpty ? "View artifact" : title,
      icon: Icons.insert_chart_outlined,
      action: Icons.open_in_new,
      background: scheme.primaryContainer,
      foreground: scheme.onPrimaryContainer,
      onTap: () => ref
          .read(linkOpenerProvider)
          .openArtifact(context, chatId, artifactId, entryFile: entryFile, title: title),
    );
  }
}

/// A `create_skill` call, once it is history: a card the user taps to review
/// and install the skill the model drafted. Important the way an artifact is,
/// for the same reason.
class SkillInstallActivity extends Activity {
  const SkillInstallActivity();

  @override
  bool important(Run run) => true;

  @override
  Widget build(Run run) => Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final SkillInstallPart(:installId, :title) = run.part! as SkillInstallPart;
        return _OutputCard(
          kind: "Skill",
          label: title.isEmpty ? "Install skill" : title,
          icon: Icons.extension,
          action: Icons.install_desktop,
          background: scheme.secondaryContainer,
          foreground: scheme.onSecondaryContainer,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  SkillInstallPreviewPage(chatId: run.chatId, installId: installId),
            ),
          ),
        );
      });
}

/// The card [ArtifactActivity] and [SkillInstallActivity] are drawn as.
class _OutputCard extends StatelessWidget {
  const _OutputCard({
    required this.kind,
    required this.label,
    required this.icon,
    required this.action,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String kind;
  final String label;
  final IconData icon;
  final IconData action;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: foreground.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 20, color: foreground),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          kind,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.75),
                            letterSpacing: 0.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(action, size: 18, color: foreground.withValues(alpha: 0.7)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

