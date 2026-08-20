import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "code_block.dart";

/// A `!` message as it reads: the command itself, in the face everything shown
/// verbatim is set in, behind a terminal mark that says it is one. Nothing here
/// renders markdown — a command is characters that have to line up, not prose.
class ShellCommandText extends StatelessWidget {
  const ShellCommandText({super.key, required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 8),
          child: Icon(Icons.terminal,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
        ),
        Flexible(child: Text(command, style: codeBlockStyle(theme))),
      ],
    );
  }
}

/// What a command the user ran came back with: its output, and under it what it
/// exited with. The reply to a `!` message is this and nothing else.
///
/// A [CodeBlock] holds the output, so it scrolls rather than wraps and carries
/// the same copy button a fenced block does. Unhighlighted: output is not a
/// language, and guessing one would colour a stack trace as though it were.
class ShellRunBubble extends StatelessWidget {
  const ShellRunBubble({super.key, required this.run});

  final ShellRunPart run;

  bool get _failed => run.returnCode != 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The trailing newline every command ends on would draw as a blank line.
    final output = run.output.trimRight();
    final problem = run.exceptionInfo;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: codeBlockDecoration(theme),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (output.isNotEmpty)
            CodeBlock(
              code: output,
              language: null,
              span: TextSpan(text: output, style: codeBlockStyle(theme)),
            ),
          if (problem != null && problem.isNotEmpty) _problem(theme, problem),
          _exit(theme, silent: output.isEmpty && (problem == null || problem.isEmpty)),
        ],
      ),
    );
  }

  Widget _problem(ThemeData theme, String problem) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Text(
          problem,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
        ),
      );

  /// The footer, and the whole of the bubble for a command that printed
  /// nothing — which is why [silent] says so there rather than leaving a strip
  /// that reads as an answer cut off.
  Widget _exit(ThemeData theme, {required bool silent}) {
    final color =
        _failed ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.labelSmall?.copyWith(color: color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(_failed ? Icons.error_outline : Icons.check_circle_outline,
              size: 14, color: color),
          const SizedBox(width: 8),
          Text("Exit code: ${run.returnCode}", style: label),
          if (silent) ...[
            const Spacer(),
            Text("no output",
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}
