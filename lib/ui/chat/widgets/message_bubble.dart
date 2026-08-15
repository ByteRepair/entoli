import "package:flutter/gestures.dart";
import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../widgets/dialogs.dart";

/// Renders a single message as a chat bubble. Text parts are concatenated;
/// tool calls and results render as monospace chips.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.isWaiting = false,
    this.waitingNotice,
    this.onEdit,
    this.onRegenerate,
  });

  final Message message;

  /// This message is the one being generated right now.
  final bool isWaiting;

  /// Trouble reported while the turn is still running, e.g. a retry after a
  /// rate limit. Shown in red beside the spinner.
  final String? waitingNotice;

  /// Resend this message with different text. User messages only.
  final ValueChanged<String>? onEdit;

  /// Run the turn this message belongs to again, unchanged.
  final VoidCallback? onRegenerate;

  Future<void> _showMenu(BuildContext context, Offset position) async {
    if (onEdit == null && onRegenerate == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        if (onEdit != null)
          const PopupMenuItem(
            value: "edit",
            child: ListTile(leading: Icon(Icons.edit), title: Text("Edit"), dense: true),
          ),
        if (onRegenerate != null)
          const PopupMenuItem(
            value: "regenerate",
            child: ListTile(leading: Icon(Icons.refresh), title: Text("Regenerate"), dense: true),
          ),
      ],
    );
    if (selected == "regenerate") {
      onRegenerate!();
    } else if (selected == "edit" && context.mounted) {
      final edited = await promptForText(
        context,
        title: "Edit message",
        initial: message.plainText,
        confirmLabel: "Send",
        maxLines: 8,
      );
      if (edited != null) onEdit!(edited);
    }
  }

  bool get _hasError => message.parts.whereType<ErrorPart>().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == MessageRole.user;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final (name, bg) = switch (message.role) {
      MessageRole.user => ("You", theme.colorScheme.primaryContainer),
      MessageRole.assistant => ("Assistant", theme.colorScheme.surfaceContainerHighest),
      MessageRole.tool => ("Tool", theme.colorScheme.tertiaryContainer),
      MessageRole.system => ("System", theme.colorScheme.tertiaryContainer),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          GestureDetector(
            // The bubble's SelectableText claims long-press for selection, so
            // touch users reach the menu through the name label instead.
            onLongPressStart: (d) => _showMenu(context, d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                name,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          Listener(
            // A raw pointer listener sidesteps the gesture arena, which
            // SelectableText would otherwise win.
            onPointerDown: (event) {
              if (event.buttons == kSecondaryMouseButton) _showMenu(context, event.position);
            },
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...message.parts.map((p) => _renderPart(p, theme)),
                  if (isWaiting && !message.hasText)
                    _Spinner(color: theme.colorScheme.onSurfaceVariant, notice: waitingNotice),
                  // A failed turn is a dead end without this; the same action
                  // is on the context menu, but it should not have to be found.
                  if (_hasError && !isWaiting && onRegenerate != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: onRegenerate,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text("Retry"),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderPart(MessagePart part, ThemeData theme) {
    return switch (part) {
      TextPart(:final text) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: SelectableText(text, style: theme.textTheme.bodyMedium),
        ),
      ToolCallPart(:final toolCall) => _ToolChip(toolCall: toolCall),
      ToolResultPart(:final result) => _ResultChip(result: result),
      ImagePart(:final path) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text("📷 $path", style: theme.textTheme.bodySmall),
        ),
      ErrorPart(:final message) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: SelectableText(
            "Error: $message",
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
          ),
        ),
    };
  }
}

/// Stands in for the reply until the first text arrives.
class _Spinner extends StatelessWidget {
  const _Spinner({required this.color, this.notice});
  final Color color;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          if (notice != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                notice!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({required this.toolCall});
  final ToolCall toolCall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal, size: 14, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 4),
              Text(
                toolCall.name,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
          if (toolCall.argumentsText != null || toolCall.argumentsJson != null)
            SelectableText(
              toolCall.argumentsText ?? toolCall.argumentsJson ?? "",
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: "monospace",
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
        ],
      ),
    );
  }
}

class _ResultChip extends StatelessWidget {
  const _ResultChip({required this.result});
  final ToolResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = result.returnCode != 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isError ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isError ? theme.colorScheme.error : theme.colorScheme.outlineVariant,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.check_circle_outline,
                size: 14,
                color: isError ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                "rc=${result.returnCode}",
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: "monospace",
                  color: isError ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (result.output.isNotEmpty)
            SelectableText(
              result.output,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: "monospace"),
              maxLines: 8,
            ),
          if (result.exceptionInfo != null)
            SelectableText(
              result.exceptionInfo!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: "monospace",
                color: theme.colorScheme.error,
              ),
              maxLines: 4,
            ),
        ],
      ),
    );
  }
}

/// Inline approval banner shown above the composer when a tool awaits approval.
class ApprovalBanner extends StatelessWidget {
  const ApprovalBanner({
    super.key,
    required this.approval,
    required this.onAllow,
    required this.onDeny,
  });

  final ToolApproval approval;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.tertiary),
      ),
      child: Row(
        children: [
          Icon(Icons.shield, size: 18, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Approve ${approval.toolName}?",
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (approval.argumentsJson != null)
                  Text(
                    approval.argumentsJson!,
                    style: theme.textTheme.bodySmall?.copyWith(fontFamily: "monospace"),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          TextButton(onPressed: onDeny, child: const Text("Deny")),
          FilledButton(onPressed: onAllow, child: const Text("Allow")),
        ],
      ),
    );
  }
}