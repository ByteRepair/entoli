import "../../../domain/permission.dart";
import "../../../domain/shell.dart" show bashToolName;
import "../../../domain/web_search.dart" show webfetchToolName;
import "../controller.dart";

/// Per tool: what it is called, with its own name beside it, and what the
/// pattern field matches for it — a command, a path or a host.
typedef _Tool = ({String name, String field, String hint});

const Map<String, _Tool> _tools = {
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

/// The answer that stores no decision: the approval mode decides.
const _noDecision = "default";

/// Null is the rule saying nothing, so the approval mode decides.
const _decisions = [
  FormOption(
    _noDecision,
    "Default (the approval mode decides)",
    help:
        "This rule doesn't change it: the approval mode in Settings "
        "decides, as for any other command (ask every time, let the "
        "classifier decide, or run everything). Pick this when the rule is "
        "only about what the command can write to.",
  ),
  FormOption(
    "allow",
    "Run without asking",
    help:
        "Runs straight away, without the approval banner or the "
        "classifier.",
  ),
  FormOption(
    "ask",
    "Ask me first",
    help:
        "Always shows the approval banner, even where the classifier or "
        "another rule would have let it through.",
  ),
  FormOption(
    "deny",
    "Block it",
    help: "Never runs. The agent is told the call was blocked by a rule.",
  ),
];

/// The form's view of a rule's sandbox, which the rule holds as
/// `unconfined` and `writes`.
enum _Scope { workspaces, folders, anywhere }

_Scope _scopeOf(PermissionRule rule) => rule.unconfined
    ? _Scope.anywhere
    : rule.writes.isEmpty
    ? _Scope.workspaces
    : _Scope.folders;

final _scopes = [
  FormOption(
    _Scope.workspaces.name,
    "Default (workspaces only)",
    help:
        "This rule doesn't change it: the command can write inside the "
        "chat and project workspaces and the project's writable "
        "directories. Everywhere else is read-only. Reading is never "
        "blocked.",
  ),
  FormOption(
    _Scope.folders.name,
    "Workspaces and these folders",
    help:
        "The default, plus the folders below, for the commands this rule "
        "matches only.",
  ),
  FormOption(
    _Scope.anywhere.name,
    "Anywhere (no sandbox)",
    help:
        "Runs with your full user permissions, as in your own terminal. "
        "For tools like podman or toolbox that write to system or runtime "
        "folders.",
  ),
];

/// What a rule's row says: tool and pattern, then its decision and what it
/// lets a command write.
CollectionItem describeRule(PermissionRule rule) => CollectionItem(
  "${_tools[rule.tool]?.name ?? rule.tool}: ${rule.pattern}",
  subtitle: [
    if (rule.decision case final decision?)
      _decisions.firstWhere((d) => d.answer == decision.name).label,
    if (rule.setsSandbox)
      switch (_scopeOf(rule)) {
        _Scope.workspaces => null,
        _Scope.folders => "Also writes to: ${rule.writes.join(", ")}",
        _Scope.anywhere => "No sandbox",
      },
  ].nonNulls.join(" · "),
);

/// One rule, asked as three questions: which calls it applies to, what
/// happens before one runs, and what a command can write to once it does.
/// Each option names an outcome, and the line under it says what that means;
/// Default is the rule leaving that question to everything else.
class PermissionRuleForm extends SettingForm<PermissionRule> {
  const PermissionRuleForm(this.rule);

  final PermissionRule? rule;

  @override
  String get title => rule == null ? "Add rule" : "Edit rule";

  @override
  Map<String, String> get initial => {
    "tool": rule?.tool ?? bashToolName,
    "pattern": rule?.pattern ?? "",
    "decision": rule == null
        ? PermissionDecision.allow.name
        : rule!.decision?.name ?? _noDecision,
    "scope": (rule == null ? _Scope.workspaces : _scopeOf(rule!)).name,
    "folders": rule?.writes.join(", ") ?? "",
  };

  /// Whether the write question applies: a command, and not a blocked one.
  /// The scope answer is kept while it does not, so switching back restores
  /// it.
  bool _asksScope(Map<String, String> a) =>
      PermissionRule.takesSandbox(a["tool"]!) && a["decision"] != "deny";

  List<String> _folders(Map<String, String> a) => [
    for (final dir in a["folders"]!.split(","))
      if (dir.trim().isNotEmpty) dir.trim(),
  ];

  bool _foldersMissing(Map<String, String> a) =>
      _asksScope(a) && a["scope"] == _Scope.folders.name && _folders(a).isEmpty;

  @override
  List<FormFieldSpec> fields(Map<String, String> a) {
    final tool = _tools[a["tool"]] ?? _tools[bashToolName]!;
    return [
      const FormQuestion("Applies to"),
      FormChoice("tool", label: "Tool", [
        for (final MapEntry(:key, :value) in _tools.entries)
          FormOption(key, value.name),
      ]),
      FormText("pattern", tool.field, hint: tool.hint, focused: rule == null),
      const FormQuestion("Before it runs"),
      const FormChoice("decision", _decisions),
      if (_asksScope(a)) ...[
        const FormQuestion("What it can write to"),
        FormChoice("scope", _scopes),
        if (a["scope"] == _Scope.folders.name)
          FormText(
            "folders",
            "Folders",
            hint: "/run/user/1000/libpod, ~/.cache/x",
            helper: "Separate folders with commas.",
            error: _foldersMissing(a)
                ? "Add at least one folder, or pick another option."
                : null,
          ),
      ],
    ];
  }

  @override
  String? problem(Map<String, String> a) {
    final made = build(a);
    if (made.pattern.isEmpty || _foldersMissing(a)) return "";
    if (made.saysNothing) {
      return "With both on Default, this rule would change nothing.";
    }
    return null;
  }

  @override
  PermissionRule build(Map<String, String> a) {
    final scope = _asksScope(a)
        ? _Scope.values.byName(a["scope"]!)
        : _Scope.workspaces;
    return PermissionRule(
      tool: a["tool"]!,
      pattern: a["pattern"]!.trim(),
      decision: PermissionDecision.values.asNameMap()[a["decision"]],
      unconfined: scope == _Scope.anywhere,
      writes: scope == _Scope.folders ? _folders(a) : const [],
    );
  }
}
