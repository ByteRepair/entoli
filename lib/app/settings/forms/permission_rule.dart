import "../../../domain/permission.dart";
import "../controller.dart";
import "../permission_rules.dart";

/// The answer that stores no decision: the approval mode decides.
const _noDecision = "default";

final _decisions = [
  for (final MapEntry(:key, :value) in ruleDecisions.entries)
    FormOption(key?.name ?? _noDecision, value.label, help: value.help),
];

final _scopes = [
  for (final MapEntry(:key, :value) in ruleScopes.entries)
    FormOption(key.name, value.label, help: value.help),
];

/// What a rule's row says: tool and pattern, then its decision and what it
/// lets a command write.
CollectionItem describeRule(PermissionRule rule) =>
    CollectionItem(ruleTitle(rule), subtitle: ruleSubtitle(rule));

/// [PermissionRuleDraft] as a form, for the settings drawn from data.
class PermissionRuleForm extends SettingForm<PermissionRule> {
  const PermissionRuleForm(this.rule);

  final PermissionRule? rule;

  @override
  String get title => rule == null ? "Add rule" : "Edit rule";

  @override
  Map<String, String> get initial {
    final draft = PermissionRuleDraft(rule);
    return {
      "tool": draft.tool,
      "pattern": draft.pattern,
      "decision": draft.decision?.name ?? _noDecision,
      "scope": draft.scope.name,
      "folders": draft.folders,
    };
  }

  PermissionRuleDraft _draft(Map<String, String> a) => PermissionRuleDraft()
    ..tool = a["tool"]!
    ..pattern = a["pattern"]!
    ..decision = PermissionDecision.values.asNameMap()[a["decision"]]
    ..scope = RuleScope.values.byName(a["scope"]!)
    ..folders = a["folders"]!;

  @override
  List<FormFieldSpec> fields(Map<String, String> a) {
    final draft = _draft(a);
    final tool = ruleTools[draft.tool] ?? ruleTools.values.first;
    return [
      const FormQuestion("Applies to"),
      FormChoice("tool", label: "Tool", [
        for (final MapEntry(:key, :value) in ruleTools.entries)
          FormOption(key, value.name),
      ]),
      FormText("pattern", tool.field, hint: tool.hint, focused: rule == null),
      const FormQuestion("Before it runs"),
      FormChoice("decision", _decisions),
      if (draft.asksScope) ...[
        const FormQuestion("What it can write to"),
        FormChoice("scope", _scopes),
        if (draft.scope == RuleScope.folders)
          FormText(
            "folders",
            "Folders",
            hint: "/run/user/1000/libpod, ~/.cache/x",
            helper: "Separate folders with commas.",
            error: draft.foldersMissing
                ? "Add at least one folder, or pick another option."
                : null,
          ),
      ],
    ];
  }

  @override
  String? problem(Map<String, String> a) => _draft(a).problem;

  @override
  PermissionRule build(Map<String, String> a) => _draft(a).rule;
}
