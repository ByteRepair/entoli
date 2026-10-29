import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../fonts.dart";
import "../tool_ui/tools.dart";

/// What the turn stops on: the agent wants to run something, and nothing moves
/// until this is answered. It sits above the composer rather than in the
/// conversation, because it is the turn asking rather than the model speaking.
///
/// The call itself is the point of it. A banner naming only the tool is asking
/// to be waved through — what is being consented to is the command, so that is
/// what the panel below shows, verbatim and in the bundled mono face. It comes
/// worded from the agent as `argumentsText`, the same way `toolRunView` takes it;
/// the raw JSON is the fallback for a tool that words nothing.
///
/// Two answers write a rule as well as allowing: **Allow in Chat** onto the
/// chat's `meta.json`, **Allow in Project** onto the project's
/// `project.json`. They are here rather than in a settings page because the
/// prompt is where the decision lives — nobody opens settings to pre-approve
/// each chat — and the rule they write is derived from the call being shown,
/// so agreeing to it and recording it are one act.
class ApprovalBanner extends StatelessWidget {
  const ApprovalBanner({
    super.key,
    required this.approval,
    required this.onAllow,
    required this.onDeny,
    this.onAlwaysAllowChat,
    this.onAlwaysAllowProject,
  });

  final ToolApproval approval;

  /// Null where a this-turn-only answer would mislead: an `add_directory`
  /// grant is asked for because the work there recurs, and a plain Allow
  /// lapsed at the next turn.
  final VoidCallback? onAllow;
  final VoidCallback onDeny;

  /// Writes the derived rule on the chat's `meta.json`. Null where this
  /// banner is drawn for a mirrored chat — the home device writes the rule.
  final VoidCallback? onAlwaysAllowChat;

  /// Writes the derived rule on the project's `project.json`. Null for a
  /// mirrored chat, and where no project is resolved.
  final VoidCallback? onAlwaysAllowProject;

  /// Past this the panel scrolls. A command long enough to need it is rare and
  /// a banner tall enough to bury the conversation behind it is worse.
  static const mostHeight = 132.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = approval.argumentsText ?? approval.argumentsJson;
    final (icon, title) = approval.unsandboxed
        ? (Icons.shield_outlined, "Run without the sandbox?")
        : toolUIFor(approval.toolName).approval;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 16, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                approval.toolName,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: monoFamily,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: mostHeight),
                child: SingleChildScrollView(
                  // Selectable so a command can be copied out and tried, or
                  // a path pasted into a rule, before answering.
                  child: SelectableText(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: monoFamily,
                      color: scheme.onSurface,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // A Wrap, not a Row: four actions on a narrow window overflow a Row
          // past the edge, and the buttons past it are drawn but untappable —
          // how the two always answers went missing in the tests. Wrapped,
          // the overflow rows sit beside the conversation.
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: onDeny,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                child: const Text("Deny"),
              ),
              if (onAlwaysAllowChat != null)
                OutlinedButton(
                    onPressed: onAlwaysAllowChat,
                    child: const Text("Always in chat")),
              if (onAlwaysAllowProject != null)
                OutlinedButton(
                    onPressed: onAlwaysAllowProject,
                    child: const Text("Always in project")),
              if (onAllow != null)
                FilledButton(onPressed: onAllow, child: const Text("Allow")),
            ],
          ),
        ],
      ),
    );
  }
}
