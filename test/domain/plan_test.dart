import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
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
      expect(planAddTask(null, "one", details: "how"),
          "# Plan\n\n## Tasks\n\n- [ ] one\n  how\n");
    });

    test("fills a section that has nothing in it yet", () {
      expect(planAddTask("# Plan\n\n## Tasks\n", "one"),
          "# Plan\n\n## Tasks\n\n- [ ] one\n");
      expect(planAddTask("## Tasks\n\n## Later\n\n- [ ] b\n", "a"),
          "## Tasks\n\n- [ ] a\n\n## Later\n\n- [ ] b\n");
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
      expect(planVerdict("split task 2"), contains("Do not start executing"));
      expect(planVerdict("split task 2"), contains("\"split task 2\""));
      expect(planVerdict(null), contains("Finish the turn"));
    });
  });

  group("presentPlanArgsFrom", () {
    test("the title is optional", () {
      expect(presentPlanArgsFrom("{}")!.title, isNull);
      expect(presentPlanArgsFrom(null), isNull);
      expect(presentPlanArgsFrom("[]"), isNull);
      expect(presentPlanArgsFrom('{"title": "T"}')!.title, "T");
    });
  });

  group("details", () {
    const plan = """
# Plan

## Setup

- [x] clone
  Clone the repo.

## Work

- [ ] fix the parser
  Read `parse.dart` first.

  - keep the old entry point
  - add a test
- [ ] write docs
""";

    test("the indented lines under a task are its details, and lists in them are not tasks", () {
      final tasks = planTasksFrom(plan);
      expect(tasks.map((t) => t.text), ["clone", "fix the parser", "write docs"]);
      expect(tasks[0].details, "Clone the repo.");
      expect(tasks[1].details,
          "Read `parse.dart` first.\n\n- keep the old entry point\n- add a test");
      expect(tasks[2].details, isEmpty);
    });

    test("tasks are grouped under their headings, numbered across them", () {
      final sections = planSectionsFrom(plan);
      expect(sections.map((s) => s.heading), ["Setup", "Work"]);
      expect(sections[1].tasks.map((t) => t.index), [2, 3]);
    });

    test("prose after a task ends its details", () {
      final tasks = planTasksFrom("- [ ] one\n  how\nSome prose.\n");
      expect(tasks.single.details, "how");
    });

    test("planMark leaves the details alone", () {
      expect(planMark(plan, 2, PlanTaskStatus.done),
          plan.replaceFirst("- [ ] fix the parser", "- [x] fix the parser"));
    });

    test("planAddTask indents the details under the task, at the section's end", () {
      final added = planAddTask(plan, "release",
          section: "Setup", details: "Tag it.\n\nThen push.");
      expect(added,
          contains("  Clone the repo.\n- [ ] release\n  Tag it.\n\n  Then push.\n\n## Work"));
      final release = planTasksFrom(added)[1];
      expect(release.text, "release");
      expect(release.details, "Tag it.\n\nThen push.");
    });

    test("planNextResult carries the details", () {
      final next = planNext(plan)!;
      expect(planNextResult(next, planProgress(plan)),
          startsWith("Task 2 of 3: fix the parser\n\nRead `parse.dart` first."));
    });
  });

  group("planApprovalQuestion", () {
    test("asks one question with the two answers, and the document round-trips", () {
      final q = planApprovalQuestion("The work");
      expect(q.question, contains("The work"));
      expect(q.options.map((o) => o.label), ["Go"]);
      expect(q.options.map((o) => o.answer), ["go"]);

      // The JSON the tool sends parses into the same pair the panel runs.
      final questions = askQuestionsFrom(planApprovalQuestionsJson("The work"));
      expect(questions, hasLength(1));
      expect(questions.single.options.map((o) => o.answer), ["go"]);
      expect(questions.single.question, contains("The work"));
      expect(askQuestionsFrom(planApprovalQuestionsJson(null)), hasLength(1));
    });
  });

  group("planRevision", () {
    Message reply(List<MessagePart> parts) => Message(
        id: "a", role: MessageRole.assistant, createdAt: DateTime(2026), parts: parts);
    ToolCallPart call(String id, String name) =>
        ToolCallPart(toolCall: ToolCall(id: id, name: name));
    ToolResultPart result(String id) =>
        ToolResultPart(result: ToolResult(callId: id, returnCode: 0, output: ""));

    test("moves on a plan tool's or a file edit's result, not on anything else", () {
      expect(planRevision([]), 0);
      expect(
          planRevision([
            reply([
              call("1", planAddToolName),
              result("1"),
              call("2", "bash"),
              result("2"),
              call("3", "edit"),
              // A call still running has changed nothing yet.
              call("4", planDoneToolName),
              const TextPart(text: "done"),
            ]),
            reply([result("3")]),
          ]),
          2);
    });
  });

}
