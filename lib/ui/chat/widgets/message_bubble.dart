import "package:flutter/gestures.dart";
import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../widgets/attachment_chip.dart";
import "../../widgets/dialogs.dart";
import "activity_label.dart";

/// Renders a single message. The bubble holds what the model said; thinking
/// and tool runs sit above it as labels, in the order they happened.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.chatId,
    required this.message,
    this.isWaiting = false,
    this.waitingNotice,
    this.onEdit,
    this.onRegenerate,
  });

  /// Which chat's `resources/` the attachments are read back from.
  final String chatId;

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
          ..._rows(context, theme, bg),
        ],
      ),
    );
  }

  /// The message split the way it reads: everything the model did on labels of
  /// its own, everything it said in a bubble, in the order it happened.
  List<Widget> _rows(BuildContext context, ThemeData theme, Color bg) {
    final rows = <Widget>[];
    final spoken = <MessagePart>[];
    final files = message.files.toList();
    var filesShown = false;

    final results = {
      for (final part in message.parts.whereType<ToolResultPart>()) part.result.callId: part.result,
    };
    final claimed = <String>{};

    // Trailing state, not parts: they belong under the last thing said.
    final extras = <Widget>[
      if (isWaiting && !message.hasText)
        _Spinner(color: theme.colorScheme.onSurfaceVariant, notice: waitingNotice),
      // A failed turn is a dead end without this; the same action is on the
      // context menu, but it should not have to be found.
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
    ];

    void closeBubble({List<Widget> trailing = const []}) {
      final showFiles = files.isNotEmpty && !filesShown;
      if (spoken.isEmpty && trailing.isEmpty && !showFiles) return;
      rows.add(_bubble(
        context,
        theme,
        bg,
        parts: spoken.toList(),
        files: showFiles ? files : const [],
        trailing: trailing,
      ));
      filesShown = true;
      spoken.clear();
    }

    for (var i = 0; i < message.parts.length; i++) {
      final part = message.parts[i];
      switch (part) {
        case ReasoningPart():
          closeBubble();
          rows.add(ThinkingLabel(
            part: part,
            isLive: isWaiting && part.durationMs == null && i == message.parts.length - 1,
          ));
        case ToolCallPart(:final toolCall):
          closeBubble();
          claimed.add(toolCall.id);
          rows.add(ToolLabel(call: toolCall, result: results[toolCall.id]));
        case ToolResultPart(:final result):
          // Already drawn by the call it answers, unless the call is gone.
          if (claimed.contains(result.callId)) continue;
          closeBubble();
          rows.add(ToolLabel(result: result));
        case FilePart():
          continue;
        case TextPart() || ErrorPart():
          spoken.add(part);
      }
    }
    closeBubble(trailing: extras);
    return rows;
  }

  Widget _bubble(
    BuildContext context,
    ThemeData theme,
    Color bg, {
    required List<MessagePart> parts,
    required List<FilePart> files,
    required List<Widget> trailing,
  }) {
    return Listener(
      // A raw pointer listener sidesteps the gesture arena, which
      // SelectableText would otherwise win.
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) _showMenu(context, event.position);
      },
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (files.isNotEmpty)
              AttachmentStrip(
                children: [
                  for (final f in files) AttachmentChip.sent(f, chatId: chatId),
                ],
              ),
            for (final part in parts) _renderPart(part, theme),
            ...trailing,
          ],
        ),
      ),
    );
  }

  /// Only what the message says reaches here; the rest is drawn as a label.
  Widget _renderPart(MessagePart part, ThemeData theme) {
    final (text, style) = switch (part) {
      TextPart(:final text) => (text, theme.textTheme.bodyMedium),
      ErrorPart(:final message) => (
          "Error: $message",
          theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
        ),
      _ => ("", theme.textTheme.bodyMedium),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectableText(text, style: style),
    );
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