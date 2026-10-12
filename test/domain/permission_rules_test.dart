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
          rulesDecideTraced([allowGit], "bash", command: "git status --short")
              ?.decision,
          PermissionDecision.allow);
    });

    test("deny outranks allow, whatever the order", () {
      expect(rulesDecideTraced([allowGit, denyGit], "bash", command: "git status")
          ?.decision, PermissionDecision.deny);
      expect(rulesDecideTraced([denyGit, allowGit], "bash", command: "git status")
          ?.decision, PermissionDecision.deny);
    });

    test("an allow covered from two tiers names each of them", () {
      // Two rules matching the same command, both allowing: neither wins, the
      // wording carries every tier that spoke for the answer — the chat's and
      // the app's, in the order the rules arrived.
      final chatAllow = PermissionRule(
          tool: "bash",
          pattern: "git *",
          decision: PermissionDecision.allow,
          origin: PermissionTier.chat);
      final appAllow = PermissionRule(
          tool: "bash",
          pattern: "git status *",
          decision: PermissionDecision.allow,
          origin: PermissionTier.defaultProject);
      final verdict = rulesDecideTraced([appAllow, chatAllow], "bash",
          command: "git status");
      expect(verdict?.decision, PermissionDecision.allow);
      expect(verdict?.tiers, [PermissionTier.defaultProject, PermissionTier.chat]);
    });

    test("an uncovered command asks", () {
      expect(rulesDecideTraced([allowGit], "bash", command: "git push"), null);
      expect(rulesDecideTraced([], "bash", command: "anything"), null);
    });

    test("a deny on one segment refuses a compound with uncovered others",
        () {
      // deny anywhere is a no for the whole: letting the rest ask would
      // offer the user a banner to re-litigate a no they already wrote.
      final verdict = rulesDecideTraced(
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
      expect(verdict?.decision, PermissionDecision.deny);
    });

    test("a rule for another tool is skipped", () {
      expect(rulesDecideTraced([allowWriteTmp], "bash", command: "cat /tmp/x"),
          null);
    });

    test("a path rule matches the subtree of its directory", () {
      expect(
          rulesDecideTraced([allowWriteTmp], "write", path: "/tmp/scratch/out.txt")
              ?.decision,
          PermissionDecision.allow);
      expect(
          rulesDecideTraced([allowWriteTmp], "write", path: "/tmp/other/out.txt"),
          null);
    });

    test("a webfetch rule matches the host and subdomains", () {
      final rule = PermissionRule(
          tool: "webfetch", pattern: "example.com", decision: PermissionDecision.allow);
      expect(
          rulesDecideTraced([rule], "webfetch",
                  url: "https://www.example.com/page?q=1")
              ?.decision,
          PermissionDecision.allow);
      expect(
          rulesDecideTraced([rule], "webfetch", url: "https://notexample.com/page"),
          null);
    });

    test("a webfetch * matches every host", () {
      const rule = PermissionRule(
          tool: "webfetch", pattern: "*", decision: PermissionDecision.allow);
      expect(
          rulesDecideTraced([rule], "webfetch", url: "https://anything.dev/")
              ?.decision,
          PermissionDecision.allow);
      expect(
          rulesDecideTraced(
                  [rule], "webfetch", url: "https://other.io/")?.decision,
          PermissionDecision.allow);
      // An ask rule on one domain still outranks the standing * — the
      // per-domain rules are the settings page's to write.
      const ask = PermissionRule(
          tool: "webfetch",
          pattern: "sensitive.example",
          decision: PermissionDecision.ask);
      expect(
          rulesDecideTraced(
                  [rule, ask], "webfetch", url: "https://sensitive.example/x")
              ?.decision,
          PermissionDecision.ask);
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

    test("a fetch URL becomes every host, not one domain", () {
      final rule = ruleFromApproval(ToolApproval(
          id: "a",
          toolName: "webfetch",
          argumentsText: "https://docs.example.com/guide",
          argumentsJson: "{}"));
      expect(rule!.pattern, "*");
      expect(globMatch("*", "anything"), isTrue);
      // The consult the standing answer covers, wherever it points.
      expect(ruleVerdictFor([rule], "webfetch", url: "https://other.org/x")
          ?.decision, PermissionDecision.allow);
    });

    test("a single fetcher command derives the network answer too", () {
      final rule = ruleFromApproval(ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "curl https://example.com/data.json"));
      expect(rule!.tool, "webfetch");
      expect(rule.pattern, "*");
      // A compound is still command-shaped: only the fetch alone writes the
      // network rule.
      final compound = ruleFromApproval(ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "cd ~/repo && curl https://example.com"));
      expect(compound!.tool, "bash");
      expect(compound.pattern, "cd ~/repo *");
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

    test("the origin is not persisted", () {
      final rules = [
        const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.deny,
            origin: PermissionTier.project),
      ];
      final back = permissionRulesFromJson(permissionRulesToJson(rules));
      // The tier is a fact of the file a rule was read from, not the rule.
      expect(back.single.origin, isNull);
    });
  });

  group("rulesDecideTraced", () {
    test("an allow carries the winning rule's tier", () {
      final verdict = rulesDecideTraced(
        [const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.allow,
            origin: PermissionTier.chat)],
        "bash",
        command: "git status",
      );
      expect(verdict!.decision, PermissionDecision.allow);
      expect(verdict.tiers, [PermissionTier.chat]);
    });

    test("a deny carries the denying tier", () {
      final verdict = rulesDecideTraced([
        const PermissionRule(
            tool: "bash",
            pattern: "git status *",
            decision: PermissionDecision.allow,
            origin: PermissionTier.chat),
        const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.deny,
            origin: PermissionTier.defaultProject),
      ], "bash", command: "git push");
      expect(verdict!.decision, PermissionDecision.deny);
      expect(verdict.tiers, [PermissionTier.defaultProject]);
    });

    test("a compound covered by two tiers carries both", () {
      final verdict = rulesDecideTraced(
        [
          const PermissionRule(
              tool: "bash",
              pattern: "git status *",
              decision: PermissionDecision.allow,
              origin: PermissionTier.chat),
          const PermissionRule(
              tool: "bash",
              pattern: "git log *",
              decision: PermissionDecision.allow,
              origin: PermissionTier.project),
        ],
        "bash",
        segments: ["git status", "git log --oneline"],
      );
      expect(verdict!.decision, PermissionDecision.allow);
      expect(verdict.tiers, [PermissionTier.chat, PermissionTier.project]);
    });

    test("a stronger rule clears the weaker tier", () {
      final verdict = rulesDecideTraced([
        const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.allow,
            origin: PermissionTier.chat),
        const PermissionRule(
            tool: "bash",
            pattern: "git push *",
            decision: PermissionDecision.deny,
            origin: PermissionTier.project),
      ], "bash", command: "git push origin");
      expect(verdict!.decision, PermissionDecision.deny);
      expect(verdict.tiers, [PermissionTier.project]);
    });

    test("a rule with no origin matches but carries no tier", () {
      final verdict = rulesDecideTraced(
        [const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.allow)],
        "bash",
        command: "git status",
      );
      expect(verdict!.decision, PermissionDecision.allow);
      expect(verdict.tiers, isEmpty);
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
}
