import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";

void main() {
  group("globMatch", () {
    test("exact text matches itself", () {
      expect(globMatch("git status", "git status"), isTrue);
      expect(globMatch("git status", "git status --short"), isFalse);
    });

    test("* spans the arguments but stops at an operator", () {
      expect(globMatch("git checkout *", "git checkout -b foo"), isTrue);
      expect(globMatch("git checkout *", "git checkout && evil"), isFalse);
      // The bare command the rule was derived from, arguments and all:
      // the pattern's trailing space is not a required one.
      expect(globMatch("git checkout *", "git checkout"), isTrue);
      expect(globMatch("git status *", "git status"), isTrue);
      expect(globMatch("git status *", "git statusfoo"), isFalse);
    });

    test("** spans anything including operators", () {
      expect(globMatch("echo**", "echo a && b"), isTrue);
    });

    test("matching ignores case and outer whitespace", () {
      expect(globMatch("LS *", "  ls -la  "), isTrue);
    });
  });

  group("rulesDecide", () {
    final allowGit = PermissionRule(
        tool: "bash", pattern: "git status *", decision: PermissionDecision.allow);
    final denyGit = PermissionRule(
        tool: "bash", pattern: "git *", decision: PermissionDecision.deny);
    final allowWriteTmp = PermissionRule(
        tool: "write",
        pattern: "/tmp/scratch",
        decision: PermissionDecision.allow,
        writes: ["/tmp/scratch"]);

    test("a matching allow runs", () {
      expect(
          rulesDecide([allowGit], "bash", command: "git status --short"),
          PermissionDecision.allow);
    });

    test("deny outranks allow, whatever the order", () {
      expect(rulesDecide([allowGit, denyGit], "bash", command: "git status"),
          PermissionDecision.deny);
      expect(rulesDecide([denyGit, allowGit], "bash", command: "git status"),
          PermissionDecision.deny);
    });

    test("an uncovered command asks", () {
      expect(rulesDecide([allowGit], "bash", command: "git push"),
          null);
      expect(rulesDecide([], "bash", command: "anything"), null);
    });

    test("a deny on one segment refuses a compound with uncovered others",
        () {
      // deny anywhere is a no for the whole: letting the rest ask would
      // offer the user a banner to re-litigate a no they already wrote.
      final verdict = rulesDecide(
        [
          PermissionRule(
              tool: "bash",
              pattern: "rm *",
              decision: PermissionDecision.deny),
        ],
        "bash",
        command: "ls -ld /tmp/probe; rm -rf /tmp/probe 2>/dev/null || true; ls -ld /tmp/probe",
        segments: [
          "ls -ld /tmp/probe",
          "rm -rf /tmp/probe 2>/dev/null",
          "true",
          "ls -ld /tmp/probe",
        ],
      );
      expect(verdict, PermissionDecision.deny);
    });

    test("a rule for another tool is skipped", () {
      expect(rulesDecide([allowWriteTmp], "bash", command: "cat /tmp/x"),
          null);
    });

    test("a path rule matches the subtree of its directory", () {
      expect(
          rulesDecide([allowWriteTmp], "write", path: "/tmp/scratch/out.txt"),
          PermissionDecision.allow);
      expect(
          rulesDecide([allowWriteTmp], "write", path: "/tmp/other/out.txt"),
          null);
    });

    test("a webfetch rule matches the host and subdomains", () {
      final rule = PermissionRule(
          tool: "webfetch", pattern: "example.com", decision: PermissionDecision.allow);
      expect(
          rulesDecide([rule], "webfetch",
              url: "https://www.example.com/page?q=1"),
          PermissionDecision.allow);
      expect(
          rulesDecide([rule], "webfetch",
              url: "https://notexample.com/page"),
          null);
    });
  });

  group("ruleFromApproval", () {
    test("a bash command becomes a prefix glob", () {
      final rule = ruleFromApproval(ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "git checkout -b foo",
          argumentsJson: '{"command": "git checkout -b foo"}'));
      expect(rule, isNotNull);
      expect(rule!.tool, "bash");
      expect(rule.pattern, "git checkout *");
      expect(rule.decision, PermissionDecision.allow);
    });

    test("a compound command keeps only the words before the first operator", () {
      final rule = ruleFromApproval(ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "git status && python3 evil.py",
          argumentsJson: "{}"));
      expect(rule!.pattern, "git status *");
    });

    test("a file tool's path becomes the pattern as written", () {
      final rule = ruleFromApproval(ToolApproval(
          id: "a", toolName: "write", argumentsText: "~/Projects/x/config.json"));
      expect(rule!.tool, "write");
      expect(rule.pattern, "~/Projects/x/config.json");
    });

    test("a fetch URL becomes the host", () {
      final rule = ruleFromApproval(ToolApproval(
          id: "a",
          toolName: "webfetch",
          argumentsText: "https://docs.example.com/guide",
          argumentsJson: "{}"));
      expect(rule!.pattern, "example.com");
    });

    test("a call carrying nothing matchable is null", () {
      expect(ruleFromApproval(ToolApproval(id: "a", toolName: "bash")), isNull);
      expect(ruleFromApproval(null), isNull);
    });

    test("a plain banner derivation carries no writes", () {
      final rule = ruleFromApproval(ToolApproval(
          id: "a", toolName: "bash", argumentsText: "python3 build.py"));
      expect(rule!.writes, isEmpty);
    });

    test("a re-prompt approval carries its denied dirs", () {
      final approval = ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "writing /home/yiannis/Projects/x",
          deniedDirs: const ["/home/yiannis/Projects/x"]);
      expect(approval.deniedDirs, ["/home/yiannis/Projects/x"]);
    });
  });

  group("JSON round trip", () {
    test("rules survive encoding", () {
      final rules = [
        const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.deny),
        PermissionRule(
            tool: "write",
            pattern: "/tmp/x",
            decision: PermissionDecision.allow,
            writes: const ["/tmp/x"]),
      ];
      final back = permissionRulesFromJson(permissionRulesToJson(rules));
      expect(back.length, 2);
      expect(back[0].tool, "bash");
      expect(back[0].decision, PermissionDecision.deny);
      expect(back[1].writes, ["/tmp/x"]);
    });

    test("a malformed entry is skipped rather than failing the file", () {
      final back = permissionRulesFromJson([
        {"tool": "bash", "pattern": "ls *", "decision": "allow"},
        "garbage",
        {"tool": "bash"},
      ]);
      expect(back.length, 1);
      expect(back.single.pattern, "ls *");
    });
  });

  group("rule tiers", () {
    test("chat rules come before project before app", () {
      final verdict = rulesDecide(
        [
          // app
          PermissionRule(
              tool: "bash", pattern: "ls *", decision: PermissionDecision.deny),
          // chat — the tier the user answered in
          PermissionRule(
              tool: "bash", pattern: "ls *", decision: PermissionDecision.allow),
        ],
        "bash",
        command: "ls -la",
      );
      // deny outranks allow regardless of tier; a chat allow only beats an
      // app-level ask or nothing.
      expect(verdict, PermissionDecision.deny);
    });
  });
}
