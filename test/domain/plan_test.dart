import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/plan.dart";

void main() {
  group("planTasksFrom", () {
    test("reads the markers the tools write", () {
      final text = "# Plan\n\n## Tasks\n\n- [ ] one\n- [~] two\n- [x] three\n";
      expect(
          planTasksFrom(text).map((t) => (t.index, t.status, t.text)),
          [
            (1, PlanTaskStatus.pending, "one"),
            (2, PlanTaskStatus.inProgress, "two"),
            (3, PlanTaskStatus.done, "three"),
          ]);
    });

    test("a bare bullet is a pending task", () {
      expect(
          planTasksFrom("- one\n* two\n").map((t) => (t.index, t.status, t.text)),
          [
            (1, PlanTaskStatus.pending, "one"),
            (2, PlanTaskStatus.pending, "two"),
          ]);
    });

    test("prose and other lists are ignored", () {
      final text = """
# Plan

Some prose, with a list that is not the plan:

1. first
2. second

## Tasks

- [ ] the only task
""";
      expect(planTasksFrom(text).map((t) => t.text), ["the only task"]);
    });

    test("null and empty read as nothing", () {
      expect(planTasksFrom(null), isEmpty);
      expect(planTasksFrom(""), isEmpty);
    });

    test("a marker with no text still counts, named for what it is", () {
      expect(planTasksFrom("- [ ]\n").single.text, "(untitled task)");
    });
  });

  group("planAddTask", () {
    test("creates the file when there is none", () {
      expect(planAddTask(null, "one"), "# Plan\n\n## Tasks\n\n- [ ] one\n");
    });

    test("appends to the section it names", () {
      final added = planAddTask("# Plan\n\n## Setup\n\n- [x] clone\n\n## Tasks\n\n- [ ] a\n",
          "b", section: "Tasks");
      expect(added, "# Plan\n\n## Setup\n\n- [x] clone\n\n## Tasks\n\n- [ ] a\n- [ ] b\n");
    });

    test("creates the section when it does not exist", () {
      final added =
          planAddTask("# Plan\n\n## Tasks\n\n- [ ] a\n", "b", section: "Later");
      expect(added, endsWith("- [ ] b\n"));
      expect(added, contains("## Later\n\n- [ ] b"));
      // Where nothing matches, the task lands at the end.
      expect(added.indexOf("- [ ] b"), greaterThan(added.indexOf("- [ ] a")));
    });

    test("the rest of the file stands", () {
      const before = "# Plan\n\nSome notes the model wrote.\n\n## Tasks\n\n- [x] a\n";
      expect(planAddTask(before, "b"), contains("Some notes the model wrote."));
    });
  });

  group("planMark", () {
    const plan = "- [ ] one\n- [ ] two\n- [ ] three\n";

    test("sets the one line the index names", () {
      expect(planMark(plan, 2, PlanTaskStatus.done),
          "- [ ] one\n- [x] two\n- [ ] three\n");
      expect(planMark(plan, 1, PlanTaskStatus.inProgress),
          "- [~] one\n- [ ] two\n- [ ] three\n");
      expect(planMark(plan, 1, PlanTaskStatus.pending), plan);
    });

    test("null where the plan has no such task", () {
      expect(planMark(plan, 4, PlanTaskStatus.done), isNull);
      expect(planMark(null, 1, PlanTaskStatus.done), isNull);
    });

    test("markers on prose lines are not tasks and are left alone", () {
      // A line the task scan does not count is not addressable by index.
      const text = "## Tasks\n\n- [ ] one\n";
      expect(planMark(text, 1, PlanTaskStatus.done), "## Tasks\n\n- [x] one\n");
    });
  });

  group("planFind", () {
    const plan = "- [x] read the code\n- [~] write tests\n- [ ] add parser\n";

    test("finds by number, and by text prefix, case-insensitively", () {
      expect(planFind(plan, "2")!.text, "write tests");
      expect(planFind(plan, "0"), isNull);
      expect(planFind(plan, "4"), isNull);
      expect(planFind(plan, "add")!.index, 3);
      expect(planFind(plan, "READ")!.index, 1);
    });

    test("ambiguous and missing are both null, for the caller to refuse", () {
      const twinned = "- [ ] write tests\n- [ ] write docs\n- [ ] add parser\n";
      expect(planFind(twinned, "wri"), isNull);
      expect(planFind(plan, "nothing"), isNull);
      expect(planFind(plan, "  "), isNull);
    });
  });

  group("planCandidates", () {
    test("the substring fallback beside planFind", () {
      const plan = "- [ ] re-read the code\n- [ ] add parser\n";
      expect(planCandidates(plan, "read").map((t) => t.index), [1]);
      expect(planCandidates(plan, "nothing"), isEmpty);
      expect(planCandidates(plan, "  "), isEmpty);
    });
  });

  group("planNext and planProgress", () {
    test("the first pending task and the counts, up to nothing left", () {
      // A plan with the work spread over the statuses.
      const partial = "- [x] one\n- [~] two\n- [ ] three\n- [ ] four\n";
      expect(planNext(partial)!.index, 3);
      expect(planProgress(partial), (1, 4));

      // Everything already in hand: nothing to take.
      const taken = "- [x] one\n- [~] two\n";
      expect(planNext(taken), isNull);
      expect(planProgress(taken), (1, 2));

      // No plan at all: nothing twice over.
      expect(planNext(null), isNull);
      expect(planProgress(null), (0, 0));
    });
  });

  group("the verdict", () {
    test("the verdict wording covers go, changes, and nothing answered", () {
      expect(planVerdict("go"), contains("Approved"));
      expect(planVerdict("go"), contains(planNextToolName));
      expect(planVerdict("changes"), contains("Do not start executing"));
      expect(planVerdict("changes"), contains("artifact_id"));
      expect(planVerdict(null), contains("Finish the turn"));
    });
  });

  group("presentPlanArgsFrom", () {
    test("everything is optional", () {
      final empty = presentPlanArgsFrom("{}")!;
      expect(empty.title, isNull);
      expect(empty.artifactId, isNull);
      expect(presentPlanArgsFrom(null), isNull);
      expect(presentPlanArgsFrom("[]"), isNull);
      final args = presentPlanArgsFrom('{"title": "T", "artifact_id": "a1"}')!;
      expect(args.title, "T");
      expect(args.artifactId, "a1");
      expect(presentPlanArgsFrom('{"artifact_id": ""}')!.artifactId, isNull);
    });
  });

  group("planHtml", () {
    test("counts and lists the tasks", () {
      const plan = "# Plan\n\n## Tasks\n\n- [x] one\n- [ ] two\n";
      final html = planHtml(plan, title: "The work");
      expect(html, contains("<title>The work</title>"));
      expect(html, contains("1 of 2 tasks done"));
      expect(html, contains("status done"));
      expect(html, contains("status pending"));
      expect(html, contains(">one</li>"));
      expect(html, contains(">todo</span>two</li>"));
    });

    test("escapes what the plan holds", () {
      final html = planHtml("- [ ] <b>bold</b> & \"quoted\"");
      expect(html, isNot(contains("<b>")));
      expect(html, contains("&lt;b&gt;"));
      expect(html, contains("&amp;"));
    });

    test("groups tasks under their headings", () {
      const plan = "# Plan\n\n## Setup\n\n- [x] clone\n\n## Work\n\n- [ ] fix\n";
      final html = planHtml(plan);
      final setup = html.indexOf(">Setup</h2>");
      final work = html.indexOf(">Work</h2>");
      expect(setup, greaterThan(0));
      expect(work, greaterThan(setup));
      expect(html.indexOf(">clone</li>"), greaterThan(setup));
      expect(html.indexOf(">fix</li>"), greaterThan(work));
    });

    test("no tasks says so rather than showing an empty list", () {
      final html = planHtml("# Plan\n\nNothing to do.");
      expect(html, contains("No tasks in the plan yet."));
    });
  });

  group("planApprovalQuestion", () {
    test("asks one question with the two answers, and the document round-trips", () {
      final q = planApprovalQuestion("The work");
      expect(q.question, contains("The work"));
      expect(q.options.map((o) => o.label), ["Go", "Request changes"]);
      expect(q.options.map((o) => o.answer), ["go", "changes"]);

      // The JSON the tool sends parses into the same pair the panel runs.
      final questions = askQuestionsFrom(planApprovalQuestionsJson("The work"));
      expect(questions, hasLength(1));
      expect(questions.single.options.map((o) => o.answer), ["go", "changes"]);
      expect(questions.single.question, contains("The work"));
      expect(askQuestionsFrom(planApprovalQuestionsJson(null)), hasLength(1));
    });
  });
}
