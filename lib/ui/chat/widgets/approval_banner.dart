import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../fonts.dart";

/// What the turn stops on: the agent wants to run something, and nothing moves
/// until this is answered. It sits above the composer rather than in the
/// conversation, because it is the turn asking rather than the model speaking.
///
/// The call itself is the point of it. A banner naming only the tool is asking
/// to be waved through — what is being consented to is the command, so that is
/// what the panel below shows, verbatim and in the bundled mono face. It comes
/// worded from the agent as `argumentsText`, the same way `ToolLabel` takes it;
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
  final VoidCallback onAllow;
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
    final detail = approval.argumentsText ?? approval.argumentsJson;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined,
                  size: 18, color: theme.colorScheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Allow ${approval.toolName}?",
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: mostHeight),
                child: SingleChildScrollView(
                  child: Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: monoFamily,
                      color: theme.colorScheme.onSurface,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onDeny, child: const Text("Deny")),
              const SizedBox(width: 4),
              if (onAlwaysAllowChat != null)
                TextButton(
                    onPressed: onAlwaysAllowChat,
                    child: const Text("Always in chat")),
              if (onAlwaysAllowProject != null)
                TextButton(
                    onPressed: onAlwaysAllowProject,
                    child: const Text("Always in project")),
              const SizedBox(width: 4),
              FilledButton(onPressed: onAllow, child: const Text("Allow")),
            ],
          ),
        ],
      ),
    );
  }
}
