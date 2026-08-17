import "dart:convert";

import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../fonts.dart";

/// What the turn stops on: the agent wants to run something, and nothing moves
/// until this is answered. It sits above the composer rather than in the
/// conversation, because it is the turn asking rather than the model speaking.
///
/// The call itself is the point of it. A banner naming only the tool is asking
/// to be waved through — what is being consented to is the command, so that is
/// what the panel below shows, verbatim and in the bundled mono face.
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

  /// Past this the panel scrolls. A command long enough to need it is rare and
  /// a banner tall enough to bury the conversation behind it is worse.
  static const mostHeight = 132.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = approvalDetail(approval.argumentsJson);
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
              const SizedBox(width: 8),
              FilledButton(onPressed: onAllow, child: const Text("Allow")),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the call actually does, out of the arguments the model wrote — the
/// command for a `bash`, the URL for a `webfetch`. Deliberately liberal, the
/// way `askQuestionsFrom` is: this is the model's JSON, and a tool whose
/// argument is not one of these is still better shown than hidden, so the
/// fallback is the arguments as they came.
///
/// Null is a call with nothing to show, which is a tool that takes none.
String? approvalDetail(String? argumentsJson) {
  final source = argumentsJson?.trim();
  if (source == null || source.isEmpty) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (_) {
    return source;
  }
  if (decoded is! Map) return source;
  // The two tools an approval ever gates, and only those: the single-argument
  // case below covers the rest without guessing at names nothing sends.
  for (final key in const ["command", "url"]) {
    final value = decoded[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  // One key of its own is the argument whatever it is called; several are worth
  // labelling, and the encoder is what labels them.
  if (decoded.length == 1) {
    final only = decoded.values.single;
    if (only is String && only.trim().isNotEmpty) return only.trim();
  }
  return const JsonEncoder.withIndent("  ").convert(decoded);
}
