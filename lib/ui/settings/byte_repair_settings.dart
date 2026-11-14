import "package:flutter/material.dart";

import "../../app/settings/controller.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/shell_run.dart" show LiveShellOutput;
import "../widgets/destructive_button.dart";
import "../widgets/settings_warning_banner.dart";

/// Tooling to set up, as the Flutter frontend draws it under its section's
/// header: what stands in its way, the command to run first, the two
/// buttons, the bar while one runs, the tools found, and the delete.
class SetupView extends StatelessWidget {
  const SetupView(this.c, {super.key});

  final SetupController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = c.blocked;
    final error = c.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (blocked != null)
          SettingsWarningBanner(
            icon: Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
            text: blocked,
          )
        else ...[
          if (c.notice case final notice?)
            SettingsWarningBanner(
              icon: Icons.info_outline,
              color: theme.colorScheme.onSurfaceVariant,
              text: notice,
            ),
          if (c.prerequisite case (:final why, :final command)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(why, style: theme.textTheme.bodySmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DecoratedBox(
                decoration: codeBlockDecoration(theme),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CodeBlock(code: command, language: "bash"),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: c.running ? null : c.setUp,
                  icon: c.running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(c.setUpLabel),
                ),
                OutlinedButton.icon(
                  onPressed: c.running ? null : c.import,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: Text(c.importLabel),
                ),
              ],
            ),
          ),
          if (c.running) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(),
            ),
          ],
          const SizedBox(height: 16),
          _ToolStatusList(c.tools),
          if (c.log case final log? when log.isNotEmpty) _SetupLog(log),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        DestructiveButton(
          icon: Icons.delete_outline,
          label: c.deleteLabel,
          confirmTitle: c.deleteConfirm.title,
          confirmMessage: c.deleteConfirm.message,
          onConfirmed: c.delete,
          enabled: !c.running,
        ),
      ],
    );
  }
}

/// What the setup printed, folded away until asked for.
class _SetupLog extends StatelessWidget {
  const _SetupLog(this.log);

  final String log;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text("Log", style: Theme.of(context).textTheme.bodyMedium),
    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
    childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
    shape: const Border(),
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SelectionArea(child: LiveShellOutput(code: log)),
      ),
    ],
  );
}

class _ToolStatusList extends StatelessWidget {
  const _ToolStatusList(this.tools);

  final Map<String, String?>? tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tools = this.tools;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: tools == null
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final MapEntry(key: tool, value: version) in tools.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 72,
                          child: Text(tool, style: theme.textTheme.bodySmall),
                        ),
                        Expanded(
                          child: Text(
                            version ?? "Not installed",
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: version != null
                                  ? theme.colorScheme.onSurfaceVariant
                                  : theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
