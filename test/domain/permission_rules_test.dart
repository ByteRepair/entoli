import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell_command_analysis.dart";

void main() {
  group("globMatch", () {
    test("exact text matches itself", () {
      expect(globMatch("git status", "git status"), isTrue);
      expect(globMatch("git status", "git status --short"), isFalse);
    });

    test("* spans the arguments, and the bare command too", () {
      expect(globMatch("git checkout *", "git checkout -b foo"), isTrue);
      // The bare command the rule was derived from, arguments and all:
      // the pattern's trailing space is not a required one.
      expect(globMatch("git checkout *", "git checkout"), isTrue);
      expect(globMatch("git status *", "git status"), isTrue);
      expect(globMatch("git status *", "git statusfoo"), isFalse);
    });

    test("a command is matched by its words: operators split it first, and "
        "redirects are not words", () {
      const make = PermissionRule(
          tool: "bash", pattern: "make *", decision: PermissionDecision.allow);
      RuleVerdict? decide(String command) => rulesDecideTraced([make], "bash",
          segments: ShellCommandAnalysis.parse(command).modelableSegments);
      expect(decide("make all 2>&1")?.decision, PermissionDecision.allow);
      expect(decide("make all &>build.log")?.decision, PermissionDecision.allow);
      expect(decide("make all && evil"), isNull,
          reason: "evil is a segment of its own, and no rule covers it");
      expect(decide("make all & evil"), isNull);
      expect(decide(r"make $(evil)"), isNull,
          reason: "words the parse cannot read are matched by no rule");
    });

    test("a rule's writes reach a command that redirects stderr", () {
      const rule = PermissionRule(
          tool: "bash",
          pattern: "{podman,toolbox} *",
          decision: PermissionDecision.allow,
          writes: ["/home/u/.local/share/containers/storage"]);
      final segments = ShellCommandAnalysis.parse(
              "toolbox run esbmc-dev esbmc --version 2>&1 | head -3")
          .modelableSegments!;
      expect(rulesSandbox([rule], segments).writes,
          ["/home/u/.local/share/containers/storage"]);
    });

    test("** is * twice", () {
      expect(globMatch("echo**", "echo a b"), isTrue);
    });

    test("matching ignores case and outer whitespace", () {
      expect(globMatch("LS *", "  ls -la  "), isTrue);
    });
  });

  group("braces", () {
    test("name the alternatives a pattern covers", () {
      expect(expandBraces("{podman,toolbox} *"), ["podman *", "toolbox *"]);
      expect(expandBraces("{a,b}{1,2}"), ["a1", "a2", "b1", "b2"]);
      expect(expandBraces("git {push,pull{,--rebase}} *"),
          ["git push *", "git pull *", "git pull--rebase *"]);
    });

    test("with no comma, or left open, are literal", () {
      expect(expandBraces("find . -exec rm {} ;"), ["find . -exec rm {} ;"]);
      expect(expandBraces("echo {a,b"), ["echo {a,b"]);
    });

    test("a rule matches any of them, per segment", () {
      const rule = PermissionRule(
          tool: "bash",
          pattern: "{podman,toolbox} *",
          decision: PermissionDecision.allow);
      RuleVerdict? decide(List<String> segments) =>
          rulesDecideTraced([rule], "bash", segments: segments);
      expect(decide(["podman ps"])?.decision, PermissionDecision.allow);
      expect(decide(["toolbox run -c x make"])?.decision,
          PermissionDecision.allow);
      expect(decide(["docker ps"]), isNull);
      expect(decide(["podman ps", "rm -rf x"]), isNull,
          reason: "the braces do not widen a segment past its operator");
    });

    test("cover hosts and paths too", () {
      const host = PermissionRule(
          tool: "webfetch",
          pattern: "{github.com,gitlab.com}",
          decision: PermissionDecision.allow);
      expect(rulesDecideTraced([host], "webfetch", url: "https://api.github.com/x")
          ?.decision, PermissionDecision.allow);
      expect(rulesDecideTraced([host], "webfetch", url: "https://example.com"),
          isNull);
    });
  });

  group("a rule's paths", () {
    String home(String path) => path.replaceFirst("~", "/home/u");

    test("are its writes and a file tool's pattern", () {
      const rule = PermissionRule(
          tool: "write",
          pattern: "~/Projects/x",
          decision: PermissionDecision.allow);
      expect(rule.withPaths(home).pattern, "/home/u/Projects/x");
      const bash = PermissionRule(
          tool: "bash", pattern: "podman *", writes: ["~/.local/share"]);
      expect(bash.withPaths(home).writes, ["/home/u/.local/share"]);
    });

    test("leave a command's pattern, which matches what was typed", () {
      const rule = PermissionRule(
          tool: "bash", pattern: "~/bin/build *", decision: PermissionDecision.allow);
      expect(rule.withPaths(home).pattern, "~/bin/build *");
    });
  });

  group("rulesSandbox", () {
    const podman = PermissionRule(
        tool: "bash", pattern: "podman *", unconfined: true);

    test("a read-only segment does not hold an unconfined run back", () {
      expect(rulesSandbox([podman], ["podman ps", "head -5"]).unconfined, isTrue);
      expect(
          rulesSandbox([podman], ["podman version", "grep -i version"]).unconfined,
          isTrue);
    });

    test("a segment that writes still does", () {
      expect(rulesSandbox([podman], ["podman ps", "touch x"]).unconfined, isFalse);
      expect(rulesSandbox([podman], ["podman ps", "echo hi > f"]).unconfined,
          isFalse);
    });

    test("read-only segments alone unconfine nothing", () {
      expect(rulesSandbox([podman], ["head -5 f", "grep x f"]).unconfined, isFalse);
      expect(rulesSandbox([podman], const []).unconfined, isFalse);
    });
  });

  group("rulesDecide", () {
    final allowGit = PermissionRule(
      tool: "bash",
      pattern: "git status *",
      decision: PermissionDecision.allow,
    );
    final denyGit = PermissionRule(
      tool: "bash",
      pattern: "git *",
      decision: PermissionDecision.deny,
    );
    final allowWriteTmp = PermissionRule(
      tool: "write",
      pattern: "/tmp/scratch",
      decision: PermissionDecision.allow,
      writes: ["/tmp/scratch"],
    );

    test("a matching allow runs", () {
      expect(
        rulesDecideTraced(
          [allowGit],
          "bash",
          segments: ["git status --short"],
        )?.decision,
        PermissionDecision.allow,
      );
    });

    test("deny outranks allow, whatever the order", () {
      expect(
        rulesDecideTraced(
          [allowGit, denyGit],
          "bash",
          segments: ["git status"],
        )?.decision,
        PermissionDecision.deny,
      );
      expect(
        rulesDecideTraced(
          [denyGit, allowGit],
          "bash",
          segments: ["git status"],
        )?.decision,
        PermissionDecision.deny,
      );
    });

    test("an allow covered from two tiers names each of them", () {
      // Two rules matching the same command, both allowing: neither wins, the
      // wording carries every tier that spoke for the answer — the chat's and
      // the app's, in the order the rules arrived.
      final chatAllow = PermissionRule(
        tool: "bash",
        pattern: "git *",
        decision: PermissionDecision.allow,
        origin: PermissionTier.chat,
      );
      final appAllow = PermissionRule(
        tool: "bash",
        pattern: "git status *",
        decision: PermissionDecision.allow,
        origin: PermissionTier.defaultProject,
      );
      final verdict = rulesDecideTraced(
        [appAllow, chatAllow],
        "bash",
        segments: ["git status"],
      );
      expect(verdict?.decision, PermissionDecision.allow);
      expect(verdict?.tiers, [
        PermissionTier.defaultProject,
        PermissionTier.chat,
      ]);
    });

    test("an uncovered command asks", () {
      expect(rulesDecideTraced([allowGit], "bash", segments: ["git push"]), null);
      expect(rulesDecideTraced([], "bash", segments: ["anything"]), null);
    });

    test("a deny on one segment refuses a compound with uncovered others", () {
      // deny anywhere is a no for the whole: letting the rest ask would
      // offer the user a banner to re-litigate a no they already wrote.
      final verdict = rulesDecideTraced(
        [
          PermissionRule(
            tool: "bash",
            pattern: "rm *",
            decision: PermissionDecision.deny,
          ),
        ],
        "bash",
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
      expect(
        rulesDecideTraced([allowWriteTmp], "bash", segments: ["cat /tmp/x"]),
        null,
      );
    });

    test("a path rule matches the subtree of its directory", () {
      expect(
        rulesDecideTraced(
          [allowWriteTmp],
          "write",
          path: "/tmp/scratch/out.txt",
        )?.decision,
        PermissionDecision.allow,
      );
      expect(
        rulesDecideTraced([allowWriteTmp], "write", path: "/tmp/other/out.txt"),
        null,
      );
    });

    test("a webfetch rule matches the host and subdomains", () {
      final rule = PermissionRule(
        tool: "webfetch",
        pattern: "example.com",
        decision: PermissionDecision.allow,
      );
      expect(
        rulesDecideTraced(
          [rule],
          "webfetch",
          url: "https://www.example.com/page?q=1",
        )?.decision,
        PermissionDecision.allow,
      );
      expect(
        rulesDecideTraced(
          [rule],
          "webfetch",
          url: "https://notexample.com/page",
        ),
        null,
      );
    });

    test("a webfetch * matches every host", () {
      const rule = PermissionRule(
        tool: "webfetch",
        pattern: "*",
        decision: PermissionDecision.allow,
      );
      expect(
        rulesDecideTraced(
          [rule],
          "webfetch",
          url: "https://anything.dev/",
        )?.decision,
        PermissionDecision.allow,
      );
      expect(
        rulesDecideTraced(
          [rule],
          "webfetch",
          url: "https://other.io/",
        )?.decision,
        PermissionDecision.allow,
      );
      // An ask rule on one domain still outranks the standing * — the
      // per-domain rules are the settings page's to write.
      const ask = PermissionRule(
        tool: "webfetch",
        pattern: "sensitive.example",
        decision: PermissionDecision.ask,
      );
      expect(
        rulesDecideTraced(
          [rule, ask],
          "webfetch",
          url: "https://sensitive.example/x",
        )?.decision,
        PermissionDecision.ask,
      );
    });
  });

  group("ruleFromApproval", () {
    test("a bash command becomes a prefix glob", () {
      final rule = ruleFromApproval(
        ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "git checkout -b foo",
          argumentsJson: '{"command": "git checkout -b foo"}',
        ),
      );
      expect(rule, isNotNull);
      expect(rule!.tool, "bash");
      expect(rule.pattern, "git checkout *");
      expect(rule.decision, PermissionDecision.allow);
    });

    test("a command that parses to no segments does not throw", () {
      final rule = ruleFromApproval(
          const ToolApproval(id: "a", toolName: "bash", argumentsText: ";"));
      expect(rule!.tool, "bash");
    });

    test(
      "a compound command keeps only the words before the first operator",
      () {
        final rule = ruleFromApproval(
          ToolApproval(
            id: "a",
            toolName: "bash",
            argumentsText: "git status && python3 evil.py",
            argumentsJson: "{}",
          ),
        );
        expect(rule!.pattern, "git status *");
      },
    );

    test("a file tool's path becomes the pattern as written", () {
      final rule = ruleFromApproval(
        ToolApproval(
          id: "a",
          toolName: "write",
          argumentsText: "~/Projects/x/config.json",
        ),
      );
      expect(rule!.tool, "write");
      expect(rule.pattern, "~/Projects/x/config.json");
    });

    test("a fetch URL becomes every host, not one domain", () {
      final rule = ruleFromApproval(
        ToolApproval(
          id: "a",
          toolName: "webfetch",
          argumentsText: "https://docs.example.com/guide",
          argumentsJson: "{}",
        ),
      );
      expect(rule!.pattern, "*");
      expect(globMatch("*", "anything"), isTrue);
      // The consult the standing answer covers, wherever it points.
      expect(
        rulesDecideTraced(
          [rule],
          "webfetch",
          url: "https://other.org/x",
        )?.decision,
        PermissionDecision.allow,
      );
    });

    test("a single fetcher command derives the network answer too", () {
      final rule = ruleFromApproval(
        ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "curl https://example.com/data.json",
        ),
      );
      expect(rule!.tool, "webfetch");
      expect(rule.pattern, "*");
      // The bare-host spelling reaches the same answer.
      final bare = ruleFromApproval(
        ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "wget example.com/data.bin",
        ),
      );
      expect(bare!.tool, "webfetch");
      expect(bare.pattern, "*");
      // What the consult would not read again derives nothing: a
      // redirecting or compound variant is command-shaped, its own shape
      // being what matched it.
      for (final command in [
        "curl https://x.com > out.txt",
        "cd ~/repo && curl https://x.com",
      ]) {
        final other = ruleFromApproval(
          ToolApproval(id: "a", toolName: "bash", argumentsText: command),
        );
        expect(other!.tool, "bash", reason: command);
      }
    });

    test("a call carrying nothing matchable is null", () {
      expect(ruleFromApproval(ToolApproval(id: "a", toolName: "bash")), isNull);
      expect(ruleFromApproval(null), isNull);
    });

    test("a plain banner derivation carries no writes", () {
      final rule = ruleFromApproval(
        ToolApproval(
          id: "a",
          toolName: "bash",
          argumentsText: "python3 build.py",
        ),
      );
      expect(rule!.writes, isEmpty);
    });
  });

  group("JSON round trip", () {
    test("rules survive encoding", () {
      final rules = [
        const PermissionRule(
          tool: "bash",
          pattern: "git *",
          decision: PermissionDecision.deny,
        ),
        const PermissionRule(
          tool: "bash",
          pattern: "make *",
          decision: PermissionDecision.allow,
          writes: ["/tmp/x"],
        ),
        const PermissionRule(
          tool: "bash",
          pattern: "podman *",
          unconfined: true,
        ),
      ];
      final back = permissionRulesFromJson(permissionRulesToJson(rules));
      expect(back.length, 3);
      expect(back[0].tool, "bash");
      expect(back[0].decision, PermissionDecision.deny);
      expect(back[0].unconfined, isFalse);
      expect(back[1].writes, ["/tmp/x"]);
      expect(back[2].decision, isNull);
      expect(back[2].unconfined, isTrue);
    });

    test("the old writes key is not read", () {
      final back = permissionRulesFromJson([
        {
          "tool": "bash",
          "pattern": "git *",
          "decision": "allow",
          "writes": ["/home/u/.gitconfig"],
        },
      ]);
      expect(back.single.unconfined, isFalse);
      expect(back.single.writes, isEmpty);
    });

    test("the origin is not persisted", () {
      final rules = [
        const PermissionRule(
          tool: "bash",
          pattern: "git *",
          decision: PermissionDecision.deny,
          origin: PermissionTier.project,
        ),
      ];
      final back = permissionRulesFromJson(permissionRulesToJson(rules));
      // The tier is a fact of the file a rule was read from, not the rule.
      expect(back.single.origin, isNull);
    });
  });

  group("rulesDecideTraced", () {
    test("an allow carries the winning rule's tier", () {
      final verdict = rulesDecideTraced(
        [
          const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.allow,
            origin: PermissionTier.chat,
          ),
        ],
        "bash",
        segments: ["git status"],
      );
      expect(verdict!.decision, PermissionDecision.allow);
      expect(verdict.tiers, [PermissionTier.chat]);
    });

    test("a deny carries the denying tier", () {
      final verdict = rulesDecideTraced(
        [
          const PermissionRule(
            tool: "bash",
            pattern: "git status *",
            decision: PermissionDecision.allow,
            origin: PermissionTier.chat,
          ),
          const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.deny,
            origin: PermissionTier.defaultProject,
          ),
        ],
        "bash",
        segments: ["git push"],
      );
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
            origin: PermissionTier.chat,
          ),
          const PermissionRule(
            tool: "bash",
            pattern: "git log *",
            decision: PermissionDecision.allow,
            origin: PermissionTier.project,
          ),
        ],
        "bash",
        segments: ["git status", "git log --oneline"],
      );
      expect(verdict!.decision, PermissionDecision.allow);
      expect(verdict.tiers, [PermissionTier.chat, PermissionTier.project]);
    });

    test("a stronger rule clears the weaker tier", () {
      final verdict = rulesDecideTraced(
        [
          const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.allow,
            origin: PermissionTier.chat,
          ),
          const PermissionRule(
            tool: "bash",
            pattern: "git push *",
            decision: PermissionDecision.deny,
            origin: PermissionTier.project,
          ),
        ],
        "bash",
        segments: ["git push origin"],
      );
      expect(verdict!.decision, PermissionDecision.deny);
      expect(verdict.tiers, [PermissionTier.project]);
    });

    test("a rule with no origin matches but carries no tier", () {
      final verdict = rulesDecideTraced(
        [
          const PermissionRule(
            tool: "bash",
            pattern: "git *",
            decision: PermissionDecision.allow,
          ),
        ],
        "bash",
        segments: ["git status"],
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

  group("rulesSandbox", () {
    const unconfinedPodman = PermissionRule(
      tool: "bash",
      pattern: "podman *",
      unconfined: true,
    );
    const makeWrites = PermissionRule(
      tool: "bash",
      pattern: "make *",
      decision: PermissionDecision.allow,
      writes: ["/opt/out"],
    );

    test("a rule with no decision says nothing about asking", () {
      expect(
          rulesDecideTraced([unconfinedPodman], "bash", segments: ["podman ps"]),
          isNull);
    });

    test("every segment unconfined runs unconfined", () {
      expect(
          rulesSandbox([unconfinedPodman], ["podman ps", "podman images"])
              .unconfined,
          isTrue);
    });

    test("one writing segment without an unconfined rule keeps the sandbox",
        () {
      expect(rulesSandbox([unconfinedPodman], ["podman ps", "touch x"]).unconfined,
          isFalse);
      expect(rulesSandbox([unconfinedPodman], const []).unconfined, isFalse);
    });

    test("writes reach only the commands their rule matches", () {
      expect(rulesSandbox([makeWrites], ["make all"]).writes, ["/opt/out"]);
      expect(rulesSandbox([makeWrites], ["npm install"]).writes, isEmpty);
    });

    test("a rule that changes nothing says so", () {
      expect(const PermissionRule(tool: "bash", pattern: "x").saysNothing,
          isTrue);
      // A sandbox on a tool that never runs in one is nothing either.
      expect(
          const PermissionRule(tool: "read", pattern: "/x", unconfined: true)
              .saysNothing,
          isTrue);
      expect(unconfinedPodman.saysNothing, isFalse);
    });

    test("a deny rule's sandbox is not applied", () {
      const denied = PermissionRule(
        tool: "bash",
        pattern: "podman *",
        decision: PermissionDecision.deny,
        unconfined: true,
      );
      expect(rulesSandbox([denied], ["podman ps"]).unconfined, isFalse);
    });
  });
}
