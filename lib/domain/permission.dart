import "models.dart"
    show PermissionDecision, PermissionTier, ToolApproval;
import "shell.dart" show pathInside;
import "shell_command_analysis.dart" show ShellCommandAnalysis;

export "models.dart" show PermissionDecision, PermissionSource, PermissionTier;

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
    this.origin,
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

  /// Which tier carried this rule, stamped by the repository when it
  /// composes a turn's settings and by the agent for a runtime grant. Not
  /// persisted — the tier is a fact of the file a rule was read from, not
  /// of the rule itself — so a rule moved between files is stamped anew
  /// rather than lying about where it came from. Null on a rule written by
  /// hand or read back alone.
  final PermissionTier? origin;

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

  /// This rule with [origin] stamped — the one field a rule gains after it
  /// is read, the tier the turn's composition found it in. Not persisted;
  /// a rule moved between files is stamped anew.
  PermissionRule copyWith({PermissionTier? origin}) => PermissionRule(
        tool: tool,
        pattern: pattern,
        decision: decision,
        writes: writes,
        origin: origin ?? this.origin,
      );

  @override
  String toString() => "$decision $tool $pattern";
}

/// Reads a persisted rule list; entries that do not parse are skipped rather
/// than failing the file, the way the rest of the settings read.
List<PermissionRule> permissionRulesFromJson(List<dynamic>? json) {
  final rules = <PermissionRule>[];
  for (final entry in json ?? const []) {
    if (entry is! Map<String, dynamic>) continue;
    if (entry["tool"] is! String || entry["pattern"] is! String) continue;
    if ((entry["pattern"] as String).isEmpty) continue;
    rules.add(PermissionRule.fromJson(entry));
  }
  return rules;
}

List<Map<String, dynamic>> permissionRulesToJson(List<PermissionRule> rules) =>
    [for (final r in rules) r.toJson()];

/// Whether [text] matches [glob], where `*` spans any run of characters
/// except a shell operator and `**` spans anything. Anchored at both ends.
/// The compiled form is cached per glob — the patterns are few and repeat
/// for the life of the process, where a regex build per match attempt would
/// be the cost of every command.
final _globCache = <String, RegExp>{};

bool globMatch(String glob, String text) {
  final pattern = _globCache.putIfAbsent(glob, () => _compileGlob(glob));
  return pattern.hasMatch(text.trim());
}

/// Compiles one glob. A glob ending in ` *` — the shape every derived rule
/// carries — covers the bare prefix too, not only the spaced arguments: the
/// command `git status` with none is the same command the rule was written
/// for, and asking again for it is the ask the rule was meant to end.
RegExp _compileGlob(String glob) {
  final spaced = RegExp(r"^(.*\S)\s\*$").firstMatch(glob.trim());
  if (spaced == null) {
    return _plainGlob(glob.trim());
  }
  final head = spaced.group(1)!;
  return RegExp(
      "^${_plainGlobBody(head)}(?:\\s[^;|&]*)?\$",
      caseSensitive: false);
}

String _plainGlobBody(String glob) =>
    RegExp.escape(glob).replaceAllMapped(RegExp(r"\\\*\\\*|\\\*"),
        (m) => m[0]!.length == 4 ? ".*" : "[^;|&]*");

RegExp _plainGlob(String glob) => RegExp(
    "^${_plainGlobBody(glob)}\$",
    caseSensitive: false);

/// What the rules say about one tool call, deny first — a deny is the user's
/// explicit no, an ask their "always show me", an allow the standing yes.
/// Null where no rule matches, which the caller escalates. The tiers arrive
/// merged, chat first; `PermissionDecision`'s declaration order is the
/// strength order, so the stronger rule wins whatever tier wrote it.
///
/// A `bash` command is matched segment by segment — [segments] are the
/// pieces a top-level operator splits it into, from the parse — and every
/// one must find an allow: a compound command whose tail no rule covers is
/// not allowed by its head. [command] is the whole string, the fallback
/// where no parse is offered.
///
/// The verdict and where it came from, together: a deny carries the tier
/// that denied; an allow carries the tiers of every rule that covered a
/// segment — a compound covered from two tiers says both — and a covered
/// subject that matched more than one tier carries each of them, the
/// wording naming the set. Null where no rule matches, which the caller
/// escalates.
RuleVerdict? rulesDecideTraced(
  List<PermissionRule> rules,
  String toolName, {
  String? command,
  List<String>? segments,
  String? path,
  String? url,
}) {
  if (toolName == "bash" && segments != null && segments.isNotEmpty) {
    PermissionDecision? verdict;
    final tiers = <PermissionTier>{};
    for (final segment in segments) {
      final segmentVerdict = _strongestTraced(rules, "bash", segment);
      final d = segmentVerdict?.decision;
      if (d == PermissionDecision.deny) {
        return (decision: PermissionDecision.deny,
            tiers: segmentVerdict!.tiers.toList());
      }
      if (d == null) {
        verdict = PermissionDecision.ask;
        continue;
      }
      verdict = _stronger(verdict, d);
      tiers.addAll(segmentVerdict!.tiers);
    }
    return verdict == PermissionDecision.ask
        ? null
        : (decision: verdict!, tiers: tiers.toList());
  }
  final subject = switch (toolName) {
    "bash" => command,
    "webfetch" => _hostOf(url),
    _ => path,
  };
  if (subject == null) return null;
  return _strongestTraced(rules, toolName, subject);
}

/// The verdict [rules] makes of one subject, with the tiers of the rules
/// that made it — the strongest decision wins; every rule at that strength
/// adds its origin, so a subject covered by two tiers says both.
RuleVerdict? _strongestTraced(
    List<PermissionRule> rules, String toolName, String subject) {
  PermissionDecision? verdict;
  final tiers = <PermissionTier>{};
  for (final rule in rules) {
    if (rule.tool != "*" && rule.tool != toolName) continue;
    if (!_ruleMatches(rule, toolName, subject)) continue;
    if (_stronger(verdict, rule.decision) != verdict) {
      // A strictly stronger decision clears the weaker tiers: they did not
      // decide this.
      tiers.clear();
      verdict = rule.decision;
    }
    if (rule.decision == verdict && rule.origin != null) tiers.add(rule.origin!);
  }
  return verdict == null ? null : (decision: verdict, tiers: tiers.toList());
}

/// The outcome of [rulesDecideTraced]: the decision and the tiers that
/// spoke for it.
typedef RuleVerdict = ({PermissionDecision decision, List<PermissionTier> tiers});

PermissionDecision? _stronger(PermissionDecision? a, PermissionDecision b) =>
    a == null || b.index > a.index ? b : a;

bool _ruleMatches(PermissionRule rule, String toolName, String subject) =>
    switch (toolName) {
      "bash" => globMatch(rule.pattern, subject),
      "webfetch" => _hostMatch(rule.pattern, subject),
      _ => pathInside(subject, rule.pattern) || globMatch(rule.pattern, subject),
    };

/// The host of [url], as the fetch itself would parse it. Null where the
/// string names none — a scheme-less or malformed URL matches nothing.
String? _hostOf(String? url) {
  if (url == null || url.isEmpty) return null;
  final host = Uri.tryParse(url)?.host;
  return host == null || host.isEmpty ? null : host;
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
///
/// A re-prompt banner's answer is not this function's — what the user agreed
/// to there is the *paths*, and the prose a model wrapped them in varies
/// every turn: those answers become directory grants (chat `writableDirs` /
/// project `writableDirs`), not command rules. A command-prose rule derived
/// from that banner would match nothing next turn while claiming to.
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

/// The matchable prefix of a command: its first two words — the command and
/// its subcommand — with ` *` appended, so the rule covers the arguments the
/// same command may carry next time. `git checkout -b foo` => `git checkout
/// *`; `ls -la` => `ls -la *`. The head is the parse's first segment, so a
/// quoted operator does not cut it mid-quote.
String _commandPrefix(String command) {
  final head = ShellCommandAnalysis.parse(command).modelableSegments?.first ??
      command;
  final words = head.split(RegExp(r"\s+"));
  final prefix = words.length <= 2 ? head : words.take(2).join(" ");
  if (prefix.isEmpty) return command;
  return "$prefix *";
}