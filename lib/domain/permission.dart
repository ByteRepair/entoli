/// How a chat handles a command before it runs.
enum ApproveMode {
  /// Every command waits for the user to allow or deny it.
  ask,

  /// A classifier model decides: safe commands run, dangerous ones are denied,
  /// and anything uncertain is escalated to the user. Falls back to [ask]
  /// when no classifier model is configured.
  auto,

  /// Every command runs without asking.
  never,
}

/// Human-readable labels for each [ApproveMode], shared by the app and chat
/// settings pages so they always agree. Each names the whole posture, not
/// just the mechanism: what runs unasked, what waits, and what can be refused
/// without the user ever seeing it.
const approveModeLabels = {
  ApproveMode.ask: "Ask before every command",
  ApproveMode.auto:
      "Auto: run what the classifier rates safe, ask on the rest",
  ApproveMode.never: "Run everything without asking (DANGEROUS)",
};

/// Reads [ApproveMode] from its persisted form, migrating the legacy
/// `approveCommands` bool (`true` → [ApproveMode.ask], `false` →
/// [ApproveMode.never]). Null when neither key is present, so a nullable
/// field reads as "inherit" and a non-null one falls back with `??`.
ApproveMode? approveModeFromJson(Map<String, dynamic> json) {
  final mode = json["approveMode"] as String?;
  if (mode != null) {
    return ApproveMode.values.firstWhere(
      (m) => m.name == mode,
      orElse: () => ApproveMode.ask,
    );
  }
  final legacy = json["approveCommands"] as bool?;
  return switch (legacy) {
    true => ApproveMode.ask,
    false => ApproveMode.never,
    null => null,
  };
}

/// What the classifier decided about a tool call.
enum PermissionDecision {
  /// Run it without asking.
  allow,

  /// Escalate to the user — emit the approval banner and wait.
  ask,

  /// Refuse it outright, without running or asking.
  deny,
}

/// Classifies a tool call as safe, uncertain, or dangerous. The one
/// implementation reaches a provider; [NoClassifier] is the safe fallback
/// that asks for everything, used when no classifier model is configured.
abstract class PermissionClassifier {
  Future<PermissionDecision> classify(
    String toolName,
    String argumentsJson, {
    required String workspace,
  });
}

/// Always asks. What auto mode falls back to when no classifier model is
/// configured: every command escalates to the banner, which is the same as
/// [ApproveMode.ask].
class NoClassifier implements PermissionClassifier {
  const NoClassifier();

  @override
  Future<PermissionDecision> classify(
    String toolName,
    String argumentsJson, {
    required String workspace,
  }) async =>
      PermissionDecision.ask;
}