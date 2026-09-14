import "models.dart" show ToolApproval;
import "shell.dart" show pathInside;

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

/// One permission rule, written at the app, project or chat tier: for [tool]
/// calls matching [pattern], the decision to take. Rules are consulted before
/// the classifier and the banner in every mode, so a rule is a standing
/// decision the user made in advance — the same answer a banner decision
/// records, applied ahead of time.
class PermissionRule {
  const PermissionRule({
    required this.tool,
    required this.pattern,
    required this.decision,
    this.writes = const [],
  });

  /// The tool the rule names: `bash`, `read`, `write`, `edit` or `webfetch`.
  /// A bare `*` names every tool.
  final String tool;

  /// What the rule matches on, read per tool:
  ///
  /// - `bash`: a glob over one command segment (`git checkout *`). Segments
  ///   are the top-level pipeline pieces — a compound command must find an
  ///   allow for every one of them.
  /// - `read` / `write` / `edit`: a path — an exact file, or a directory the
  ///   subtree of.
  /// - `webfetch`: a host name, matching itself and subdomains.
  final String pattern;

  /// What a matching call does.
  final PermissionDecision decision;

  /// Directories a rule-allowed `bash` command may additionally write to,
  /// inside the Landlock grant — the extra writable roots the sandbox grants
  /// when this rule allows the command. Empty otherwise; other tools ignore
  /// it. This is what makes "allow, and write there" a single answer rather
  /// than an allow the kernel then refuses.
  final List<String> writes;

  factory PermissionRule.fromJson(Map<String, dynamic> json) => PermissionRule(
        tool: json["tool"] as String? ?? "*",
        pattern: json["pattern"] as String? ?? "",
        decision: _decision(json["decision"] as String?),
        writes: [
          for (final w in (json["writes"] as List<dynamic>? ?? const []))
            if (w is String) w,
        ],
      );

  static PermissionDecision _decision(String? name) => switch (name) {
        "deny" => PermissionDecision.deny,
        "allow" => PermissionDecision.allow,
        _ => PermissionDecision.ask,
      };

  Map<String, dynamic> toJson() => {
        "tool": tool,
        "pattern": pattern,
        "decision": decision.name,
        if (writes.isNotEmpty) "writes": writes,
      };

  Map<String, dynamic> encode() => toJson();

  factory PermissionRule.decode(Map<String, dynamic> json) =>
      PermissionRule.fromJson(json);

  @override
  String toString() => "$decision $tool $pattern";
}

/// Reads a persisted rule list; entries that do not parse are skipped rather
/// than failing the file, the way the rest of the settings read.
List<PermissionRule> permissionRulesFromJson(List<dynamic>? json) {
  final rules = <PermissionRule>[];
  for (final entry in json ?? const []) {
    if (entry is! Map<String, dynamic>) continue;
    final tool = entry["tool"] as String?;
    final pattern = entry["pattern"] as String?;
    if (tool == null || pattern == null || pattern.isEmpty) continue;
    rules.add(PermissionRule(
      tool: tool,
      pattern: pattern,
      decision: switch (entry["decision"] as String?) {
        "deny" => PermissionDecision.deny,
        "allow" => PermissionDecision.allow,
        _ => PermissionDecision.ask,
      },
      writes: [
        for (final w in (entry["writes"] as List<dynamic>? ?? const []))
          if (w is String) w,
      ],
    ));
  }
  return rules;
}

List<Map<String, dynamic>> permissionRulesToJson(List<PermissionRule> rules) =>
    [for (final r in rules) r.toJson()];

/// Splits a bash command into the segments rules are matched against: the
/// pieces a top-level `|`, `;`, `&&`, `||` or newline separates, in order.
/// A command of one segment is itself. Substitution bodies are walked as
/// segments too, so a rule cannot allow a command into an inner command the
/// rule does not cover.
List<String> bashCommandSegments(String command) => [
      for (final piece in command.split(RegExp(r"\|\||&&|[;|\n]")))
        if (piece.trim().isNotEmpty) piece.trim(),
    ];

/// Whether [text] matches [glob], where `*` spans any run of characters
/// except a shell operator and `**` spans anything. Anchored at both ends.
bool globMatch(String glob, String text) {
  final escaped = StringBuffer("^");
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == "*" && glob.startsWith("**", i)) {
      escaped.write(".*");
      i++;
    } else if (c == "*") {
      escaped.write("[^;|&]*");
    } else {
      escaped.write(RegExp.escape(c));
    }
  }
  escaped.write(r"$");
  return RegExp(escaped.toString(), caseSensitive: false).hasMatch(text.trim());
}

/// The verdict a rule set makes of one tool call.
enum RuleOutcome {
  /// A matching allow rule covers the call.
  allow,

  /// A matching ask rule, or no rule at all — the caller escalates.
  ask,

  /// A matching deny rule refuses the call.
  deny,
}

/// What the rules say about one tool call, deny first — a deny is the user's
/// explicit no, an ask their "always show me", an allow the standing yes.
/// The tiers arrive merged, chat first, so a later same-tool rule loses to an
/// earlier one at the same strength.
RuleOutcome rulesDecide(
  List<PermissionRule> rules,
  String toolName, {
  String? command,
  String? path,
  String? url,
}) {
  RuleOutcome? verdict;
  for (final rule in rules) {
    if (rule.tool != "*" && rule.tool != toolName) continue;
    final subject = switch (toolName) {
      "bash" => command,
      "webfetch" => _hostOf(url),
      _ => path,
    };
    if (subject == null) continue;
    if (!_ruleMatches(rule, toolName, subject)) continue;
    // Deny outranks ask outranks allow, whatever tier the rules came from.
    final strength = switch (rule.decision) {
      PermissionDecision.deny => 2,
      PermissionDecision.ask => 1,
      PermissionDecision.allow => 0,
    };
    final incumbent = switch (verdict) {
      null => -1,
      RuleOutcome.deny => 2,
      RuleOutcome.ask => 1,
      RuleOutcome.allow => 0,
    };
    if (strength > incumbent) {
      verdict = switch (rule.decision) {
        PermissionDecision.deny => RuleOutcome.deny,
        PermissionDecision.ask => RuleOutcome.ask,
        PermissionDecision.allow => RuleOutcome.allow,
      };
    }
  }
  return verdict ?? RuleOutcome.ask;
}

bool _ruleMatches(PermissionRule rule, String toolName, String subject) {
  final matched = switch (toolName) {
    "bash" => globMatch(rule.pattern, subject),
    "webfetch" => _hostMatch(rule.pattern, subject),
    _ => pathInside(subject, rule.pattern) || globMatch(rule.pattern, subject),
  };
  if (!matched) return false;
  return true;
}

/// The host of [url], read out of the scheme-less remainder. Null where the
/// string names none.
String? _hostOf(String? url) {
  if (url == null || url.isEmpty) return null;
  final rest = url.startsWith("http://") || url.startsWith("https://")
      ? url.substring(url.indexOf("://") + 3)
      : url;
  final end = rest.indexOf(RegExp(r"[/:?#]"));
  return (end < 0 ? rest : rest.substring(0, end)).toLowerCase();
}

/// A host pattern matches itself and its subdomains: `example.com` covers
/// `www.example.com` and `example.com`, not `notexample.com`.
bool _hostMatch(String pattern, String host) {
  final p = pattern.toLowerCase();
  return host == p || host.endsWith(".$p");
}

/// The standing rule an "Allow in Chat" or "Allow in Project" banner answer
/// writes. Read from what the call carried: a `bash` command becomes a glob
/// over its leading words up to the first operator (`git checkout *`), a file
/// tool's path becomes its directory's scope, a fetch URL becomes the host.
/// Null where the call carries nothing matchable.
PermissionRule? ruleFromApproval(ToolApproval? approval) {
  if (approval == null) return null;
  switch (approval.toolName) {
    case "bash":
      final command = approval.argumentsText ?? "";
      if (command.trim().isEmpty) return null;
      return PermissionRule(
        tool: "bash",
        pattern: _commandPrefix(command.trim()),
        decision: PermissionDecision.allow,
      );
    case "read" || "write" || "edit":
      final path = approval.argumentsText ?? "";
      if (path.trim().isEmpty) return null;
      return PermissionRule(
        tool: approval.toolName,
        pattern: path.trim(),
        decision: PermissionDecision.allow,
      );
    case "webfetch":
      final host = _hostOf(approval.argumentsText);
      if (host == null) return null;
      // The registrable two-label suffix rather than the whole host: the
      // rule covers what the fetch reached next time, and matching is
      // subdomain-inclusive, so docs.example.com is covered by example.com.
      final labels = host.split(".");
      final registrable =
          labels.length <= 2 ? host : labels.sublist(labels.length - 2).join(".");
      return PermissionRule(
        tool: "webfetch",
        pattern: registrable,
        decision: PermissionDecision.allow,
      );
    default:
      return null;
  }
}

/// The matchable prefix of one command segment: its words up to the first
/// shell operator or substitution, with ` *` appended so the rule covers the
/// arguments the same command may carry next time. `git checkout -b foo` =>
/// The matchable prefix of one command segment: its first two words — the
/// command and its subcommand — with ` *` appended, so the rule covers the
/// arguments the same command may carry next time. `git checkout -b foo` =>
/// `git checkout *`; `ls -la` => `ls -la *`.
String _commandPrefix(String command) {
  final cut = RegExp(r"[\n|;&`$<>]").firstMatch(command);
  final head = (cut == null ? command : command.substring(0, cut.start)).trim();
  final words = head.split(RegExp(r"\s+"));
  final prefix = words.length <= 2 ? head : words.take(2).join(" ");
  if (prefix.isEmpty) return command;
  return "$prefix *";
}