import "dart:convert";

import "ask.dart";
import "models.dart";
import "tool_arg.dart";

/// The tool names, named here rather than beside the schemas, for the same
/// reason `artifactToolName` is: the agent dispatches on these, and what has
/// to recognise a call by name — the dispatch, a test, a sync peer, the chat
/// drawing a presented plan — reads this file rather than trusting the schema
/// it was sent.
const planAddToolName = "plan_add";
const planNextToolName = "plan_next";
const planDoneToolName = "plan_done";
const presentPlanToolName = "present_plan";

/// The calls that can have changed the plan by the time their result lands:
/// the plan tools, and the file tools the model edits `PLAN.md` with.
const _planWriters = {
  planAddToolName,
  planNextToolName,
  planDoneToolName,
  presentPlanToolName,
  "write",
  "edit",
};

/// How many results of [_planWriters] calls [messages] hold: a number that
/// moves whenever the plan may have, and only then, so a reader of the file
/// — across the sync channel, on a mirror — asks again on that and not on
/// every part of a turn. A `bash` that rewrote the file is missed until the
/// next of these lands.
int planRevision(List<Message> messages) {
  final writers = {
    for (final message in messages)
      for (final part in message.parts)
        if (part case ToolCallPart(
          :final toolCall,
        ) when _planWriters.contains(toolCall.name))
          toolCall.id,
  };
  var revision = 0;
  for (final message in messages) {
    for (final part in message.parts) {
      if (part case ToolResultPart(
        :final result,
      ) when writers.contains(result.callId)) {
        revision++;
      }
    }
  }
  return revision;
}

/// Where the plan lives, relative to the chat's own workspace — the directory
/// the model works in, so the model can read it and edit it around the tools.
const planFileName = "PLAN.md";

/// The section a task goes to when the model did not name one.
const planDefaultSection = "Tasks";

/// One task of the plan: its line, and the plan for it indented under that.
class PlanTask {
  const PlanTask({
    required this.index,
    required this.status,
    required this.text,
    this.details = "",
  });

  /// The task's number as the tools speak it: 1-based, in file order.
  final int index;

  final PlanTaskStatus status;
  final String text;

  /// How the task will be done, as markdown, dedented; empty where the task
  /// has none.
  final String details;
}

enum PlanTaskStatus { pending, inProgress, done }

/// The tasks filed under one heading of the plan.
class PlanSection {
  const PlanSection(this.heading, this.tasks);
  final String heading;
  final List<PlanTask> tasks;
}

/// All compiled once: `_taskLine` runs once per line of the plan file, and a
/// parse runs several times per tool call — the pattern `workspace.dart`
/// names ("Both compiled once").
///
/// A task is a bullet at the start of a line. An indented line under it is
/// its details, so a list inside a task's plan is not a task of its own.
final _bullet = RegExp(r"^[-*]\s+(.*)$");
final _marker = RegExp(r"^\[([ xX~])\]\s*(.*)$");
final _markerOnly = RegExp(r"\[[ xX~]\]");
final _hashes = RegExp(r"^#+\s*");

/// How far a task's details are indented under its line: a markdown list
/// item's continuation.
const _detailIndent = "  ";

/// The plan's tasks, grouped under the headings they sat under, numbering
/// from 1 across the whole file.
///
/// Liberal, because the file is also the model's own writing: a task is a
/// list line whose marker is one of the plan statuses — a bare bullet counts
/// as pending, so a plan written by hand still reads. Prose and other lists
/// are ignored. A task written before any heading sits under the default
/// one; the tools' own first line, `# Plan`, names nothing, since a heading
/// with no tasks under it is not a section.
List<PlanSection> planSectionsFrom(String? text) {
  if (text == null) return const [];
  final sections = <PlanSection>[];
  var heading = planDefaultSection;
  var tasks = <PlanTask>[];
  var index = 0;
  // The task being read and its detail lines, held until the next line that
  // is neither, since only then are the details known to be over.
  ({PlanTaskStatus status, String? text})? open;
  final details = <String>[];

  void closeTask() {
    if (open == null) return;
    tasks.add(
      PlanTask(
        index: ++index,
        status: open!.status,
        text: open!.text ?? "(untitled task)",
        details: _dedent(details),
      ),
    );
    open = null;
    details.clear();
  }

  void closeSection() {
    closeTask();
    if (tasks.isNotEmpty) sections.add(PlanSection(heading, tasks));
    tasks = [];
  }

  for (final line in text.split("\n")) {
    if (open != null &&
        (line.trim().isEmpty || line.startsWith(RegExp(r"\s")))) {
      details.add(line);
      continue;
    }
    if (line.startsWith("#")) {
      closeSection();
      final named = line.replaceFirst(_hashes, "").trim();
      heading = named.isEmpty ? planDefaultSection : named;
      continue;
    }
    closeTask();
    open = _taskLine(line);
  }
  closeSection();
  return sections;
}

/// The tasks of a plan file's text, in file order, numbering from 1.
List<PlanTask> planTasksFrom(String? text) => [
  for (final section in planSectionsFrom(text)) ...section.tasks,
];

String _dedent(List<String> lines) => [
  for (final line in lines)
    line.startsWith(_detailIndent)
        ? line.substring(_detailIndent.length)
        : line.trimLeft(),
].join("\n").trim();

({PlanTaskStatus status, String? text})? _taskLine(String line) {
  final bullet = _bullet.firstMatch(line);
  if (bullet == null) return null;
  final rest = bullet.group(1)!.trimLeft();
  final marked = _marker.firstMatch(rest);
  if (marked != null) {
    final marker = marked.group(1)!;
    final status = switch (marker) {
      "x" || "X" => PlanTaskStatus.done,
      "~" => PlanTaskStatus.inProgress,
      _ => PlanTaskStatus.pending,
    };
    final text = marked.group(2)!.trim();
    return (status: status, text: text.isEmpty ? null : text);
  }
  // A bare bullet is a task somebody wrote before there was a marker for it.
  final plain = rest.trim();
  if (plain.isEmpty) return null;
  return (status: PlanTaskStatus.pending, text: plain);
}

/// How many tasks are done and how many there are.
(int done, int total) planProgress(String? text) =>
    progressOf(planTasksFrom(text));

/// How many of [tasks] are done, and of how many.
(int done, int total) progressOf(List<PlanTask> tasks) =>
    (tasks.where((t) => t.status == PlanTaskStatus.done).length, tasks.length);

/// [progressOf] every task under [sections].
(int done, int total) sectionsProgress(List<PlanSection> sections) =>
    progressOf([for (final s in sections) ...s.tasks]);

/// The first task neither done nor in progress, or null.
PlanTask? planNext(String? text) => planTasksFrom(
  text,
).where((t) => t.status == PlanTaskStatus.pending).firstOrNull;

/// [task] as the model named it — the number [planNext] reported, or enough
/// of the task's text to identify it — matched against the plan's tasks.
/// Null where nothing matches; null where the text names several, since the
/// caller refuses rather than guesses.
PlanTask? planFind(String? text, String task) {
  final tasks = planTasksFrom(text);
  final trimmed = task.trim();
  if (trimmed.isEmpty) return null;
  final n = int.tryParse(trimmed);
  if (n != null) return n < 1 || n > tasks.length ? null : tasks[n - 1];
  final needle = trimmed.toLowerCase();
  final hits = tasks
      .where((t) => t.text.toLowerCase().startsWith(needle))
      .toList();
  return hits.length == 1 ? hits.single : null;
}

/// The tasks whose text holds [task], case-insensitively — what a refusal
/// names when [planFind] matched nothing. The matcher's fallback, beside the
/// matcher, so the two cannot drift apart.
List<PlanTask> planCandidates(String? text, String task) {
  final needle = task.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  return planTasksFrom(
    text,
  ).where((t) => t.text.toLowerCase().contains(needle)).toList();
}

/// Add [task] to the end of [section], with [details] indented under it,
/// creating the heading where neither the section nor the file exists yet.
/// The rest of the file stands, since the prose in it is not ours to rewrite.
String planAddTask(
  String? text,
  String task, {
  String? section,
  String details = "",
}) {
  final body = text ?? "";
  final named = section?.trim() ?? "";
  final heading = named.isEmpty ? planDefaultSection : named;
  final entry = [
    "- [ ] ${task.trim()}",
    for (final line in details.trim().split("\n"))
      if (details.trim().isNotEmpty)
        line.trim().isEmpty ? "" : "$_detailIndent${line.trimRight()}",
  ];
  if (body.trim().isEmpty) {
    return "# Plan\n\n## $heading\n\n${entry.join("\n")}\n";
  }
  final lines = body.split("\n");
  var at = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() != "## $heading") continue;
    // The section runs to the next heading; the task goes after whatever it
    // holds, ahead of the blank lines that close it.
    at = i + 1;
    while (at < lines.length && !lines[at].startsWith("#")) {
      at++;
    }
    while (at > i + 1 && lines[at - 1].trim().isEmpty) {
      at--;
    }
    // A section with nothing in it yet keeps the blank line under its
    // heading.
    if (at == i + 1) {
      final rest = lines.sublist(at).skipWhile((l) => l.trim().isEmpty);
      return [...lines.sublist(0, at), "", ...entry, "", ...rest].join("\n");
    }
    break;
  }
  // A section nobody wrote yet is opened at the end, so the task is not
  // filed under whatever heading came before it.
  if (at < 0) {
    return "${body.trimRight()}\n\n## $heading\n\n${entry.join("\n")}\n";
  }
  return [...lines.sublist(0, at), ...entry, ...lines.sublist(at)].join("\n");
}

/// Set the task at [index] (1-based, as [planTasksFrom] numbers them) to
/// [status]. The one line's marker is rewritten; everything else stands.
/// Null where the plan has no such task.
String? planMark(String? text, int index, PlanTaskStatus status) {
  if (text == null) return null;
  final lines = text.split("\n");
  var at = 0;
  for (var i = 0; i < lines.length; i++) {
    if (_taskLine(lines[i]) == null) continue;
    at++;
    if (at != index) continue;
    final marker = switch (status) {
      PlanTaskStatus.pending => "[ ]",
      PlanTaskStatus.inProgress => "[~]",
      PlanTaskStatus.done => "[x]",
    };
    lines[i] = _markerOnly.hasMatch(lines[i])
        ? lines[i].replaceFirst(_markerOnly, marker)
        : lines[i].replaceFirst(RegExp(r"^([-*]\s+)"), "\$1$marker ");
    return lines.join("\n");
  }
  return null;
}

/// The `plan_add` tool's result: what was added and where the plan stands.
/// No index is claimed: where the task went is a section's end, which is not
/// necessarily the plan's end, and the numbers the model uses are the ones
/// `plan_next` reports.
String planAddResult(String task, (int done, int total) progress) =>
    "Added: ${task.trim()}. ${progress.$2} task(s) in the plan, "
    "${progress.$1} done.";

/// The `plan_next` tool's result: the task and the plan written for it, so
/// the work starts from what the user approved.
String planNextResult(PlanTask task, (int done, int total) progress) => [
  "Task ${task.index} of ${progress.$2}: ${task.text}",
  if (task.details.isNotEmpty) task.details,
].join("\n\n");

/// The `plan_done` tool's result.
String planDoneResult(PlanTask task, (int done, int total) progress) =>
    "Task ${task.index} done: ${task.text}. ${progress.$1} of ${progress.$2} "
    "tasks done.";

/// The verdict `present_plan` asks with: one question, fixed, the plan drawn
/// in the chat above it. Go is the one option, machine-readable so the
/// verdict reads as an outcome of presenting; anything else is what the user
/// typed into the panel's own answer, and is the change they want. A bare
/// "request changes" button used to be the other option, and it ended the
/// question with nothing said about what to change.
AskQuestion planApprovalQuestion(String? title) => AskQuestion(
  question: title == null || title.isEmpty
      ? "Approve this plan?"
      : "Approve the plan \"$title\"?",
  summary:
      "The plan is in the chat above; tap a task to read its plan. "
      "Go starts the work; to change it, type what to adjust.",
  options: const [AskOption(label: "Go", value: "go")],
);

/// The question as another device reads it off a `present_plan` call's
/// arguments, in the one shape `askQuestionsFrom` round-trips. The call's
/// arguments are not questions — they name a title — so the questions, not
/// the tool args, are what travels as `AskRequest.argumentsJson`.
String planApprovalQuestionsJson(String? title) => const JsonEncoder().convert({
  "questions": [
    for (final question in [planApprovalQuestion(title)])
      {
        "question": question.question,
        "summary": question.summary,
        "options": [
          for (final option in question.options)
            {
              "label": option.label,
              "value": option.answer,
              if (option.detail != null) "detail": option.detail,
            },
        ],
      },
  ],
});

/// What `present_plan` reports, from the verdict the panel handed back. It
/// rides in the tool result, so the projection words it the same way whether
/// the turn is running now or being read back out of the log.
String planVerdict(String? verdict) => switch (verdict) {
  "go" =>
    "Approved: the user pressed Go. Start working through the plan with "
        "$planNextToolName and $planDoneToolName, one task at a time.",
  null =>
    "No verdict was reached. Finish the turn; do not start executing "
        "the plan.",
  final changes =>
    "The user asked for changes: \"$changes\". Revise the plan "
        "(edit $planFileName, or add tasks with $planAddToolName) and "
        "present it again. Do not start executing until the answer is Go.",
};

/// A `present_plan` call's title, the plan's name in the chat and on the
/// question. Everything is optional, so only a body that is not an object at
/// all fails.
({String? title})? presentPlanArgsFrom(String? json) {
  if (decodeArgs(json) == null) return null;
  return (title: stringArg(json, "title"));
}
