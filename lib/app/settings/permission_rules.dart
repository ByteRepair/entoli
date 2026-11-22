import "../../domain/permission.dart";
import "../../domain/shell.dart" show bashToolName;
import "../../domain/web_search.dart" show webfetchToolName;

/// Per tool: what it is called, with its own name beside it, and what the
/// pattern field matches for it — a command, a path or a host.
typedef RuleTool = ({String name, String field, String hint});

const Map<String, RuleTool> ruleTools = {
  bashToolName: (
    name: "Shell commands (bash)",
    field: "Command",
    hint: "{podman,toolbox} *   (* any arguments, {a,b} either)",
  ),
  "read": (
    name: "Reading files (read)",
    field: "File or folder",
    hint: "~/Projects/x",
  ),
  "write": (
    name: "Writing files (write)",
    field: "File or folder",
    hint: "~/Projects/x",
  ),
  "edit": (
    name: "Editing files (edit)",
    field: "File or folder",
    hint: "~/Projects/x",
  ),
  webfetchToolName: (
    name: "Web fetches (webfetch)",
    field: "Domain",
    hint: "example.com   (subdomains included)",
  ),
  "*": (
    name: "Every tool (*)",
    field: "Pattern",
    hint: "a command, a path or a domain",
  ),
};

typedef RuleOption = ({String label, String help});

/// Null is the rule saying nothing, so the approval mode decides.
const Map<PermissionDecision?, RuleOption> ruleDecisions = {
  null: (
    label: "Default (the approval mode decides)",
    help:
        "This rule doesn't change it: the approval mode in Settings "
        "decides, as for any other command (ask every time, let the "
        "classifier decide, or run everything). Pick this when the rule is "
        "only about what the command can write to.",
  ),
  PermissionDecision.allow: (
    label: "Run without asking",
    help:
        "Runs straight away, without the approval banner or the "
        "classifier.",
  ),
  PermissionDecision.ask: (
    label: "Ask me first",
    help:
        "Always shows the approval banner, even where the classifier or "
        "another rule would have let it through.",
  ),
  PermissionDecision.deny: (
    label: "Block it",
    help: "Never runs. The agent is told the call was blocked by a rule.",
  ),
};

/// A rule's sandbox as the form asks it; the rule holds it as `unconfined`
/// and `writes`.
enum RuleScope { workspaces, folders, anywhere }

RuleScope ruleScopeOf(PermissionRule rule) => rule.unconfined
    ? RuleScope.anywhere
    : rule.writes.isEmpty
    ? RuleScope.workspaces
    : RuleScope.folders;

const Map<RuleScope, RuleOption> ruleScopes = {
  RuleScope.workspaces: (
    label: "Default (workspaces only)",
    help:
        "This rule doesn't change it: the command can write inside the "
        "chat and project workspaces and the project's writable "
        "directories. Everywhere else is read-only. Reading is never "
        "blocked.",
  ),
  RuleScope.folders: (
    label: "Workspaces and these folders",
    help:
        "The default, plus the folders below, for the commands this rule "
        "matches only.",
  ),
  RuleScope.anywhere: (
    label: "Anywhere (no sandbox)",
    help:
        "Runs with your full user permissions, as in your own terminal. "
        "For tools like podman or toolbox that write to system or runtime "
        "folders.",
  ),
};

/// A rule's row: tool and pattern.
String ruleTitle(PermissionRule rule) =>
    "${ruleTools[rule.tool]?.name ?? rule.tool}: ${rule.pattern}";

/// Its decision and what it lets a command write.
String ruleSubtitle(PermissionRule rule) => [
  if (rule.decision case final decision?) ruleDecisions[decision]!.label,
  if (rule.setsSandbox)
    switch (ruleScopeOf(rule)) {
      RuleScope.workspaces => null,
      RuleScope.folders => "Also writes to: ${rule.writes.join(", ")}",
      RuleScope.anywhere => "No sandbox",
    },
].nonNulls.join(" · ");

/// A rule being written, asked as three questions: which calls it applies
/// to, what happens before one runs, and what a command can write to once
/// it does.
class PermissionRuleDraft {
  PermissionRuleDraft([PermissionRule? rule])
    : tool = rule?.tool ?? bashToolName,
      pattern = rule?.pattern ?? "",
      decision = rule == null ? PermissionDecision.allow : rule.decision,
      scope = rule == null ? RuleScope.workspaces : ruleScopeOf(rule),
      folders = rule?.writes.join(", ") ?? "";

  String tool;
  String pattern;
  PermissionDecision? decision;

  /// Kept while [asksScope] is false, so switching back restores it.
  RuleScope scope;

  /// Comma-separated.
  String folders;

  /// Whether the write question applies: a command, and not a blocked one.
  bool get asksScope =>
      PermissionRule.takesSandbox(tool) && decision != PermissionDecision.deny;

  List<String> get folderList => [
    for (final dir in folders.split(","))
      if (dir.trim().isNotEmpty) dir.trim(),
  ];

  bool get foldersMissing =>
      asksScope && scope == RuleScope.folders && folderList.isEmpty;

  PermissionRule get rule {
    final scope = asksScope ? this.scope : RuleScope.workspaces;
    return PermissionRule(
      tool: tool,
      pattern: pattern.trim(),
      decision: decision,
      unconfined: scope == RuleScope.anywhere,
      writes: scope == RuleScope.folders ? folderList : const [],
    );
  }

  /// Why it cannot be saved, or null where it can. Empty where a field
  /// already says so, or where there is nothing to say yet.
  String? get problem {
    final made = rule;
    if (made.pattern.isEmpty || foldersMissing) return "";
    if (made.saysNothing) {
      return "With both on Default, this rule would change nothing.";
    }
    return null;
  }
}
