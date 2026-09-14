import "dart:convert";

import "ask.dart";
import "tool_arg.dart";

/// The tool names, named here rather than beside the schemas, for the same
/// reason `artifactToolName` is: the agent dispatches on these, and what has
/// to recognise a call by name — the dispatch, a test, a sync peer — reads
/// this file rather than trusting the schema it was sent.
const planAddToolName = "plan_add";
const planNextToolName = "plan_next";
const planDoneToolName = "plan_done";
const presentPlanToolName = "present_plan";

/// Where the plan lives, relative to the chat's own workspace — the directory
/// the model works in, so the model can read it and edit it around the tools.
const planFileName = "PLAN.md";

/// Where `present_plan` writes the HTML it publishes from, relative to the
/// workspace. A dot-name so the plan page reads as machinery beside work.
const planHtmlPath = ".plan/plan.html";

/// How the tools' first line of a new plan reads.
const planHeading = "# Plan";

/// The section a task goes to when the model did not name one.
const planDefaultSection = "Tasks";

/// One task line of the plan.
class PlanTask {
  const PlanTask({required this.index, required this.status, required this.text});

  /// The task's number as the tools speak it: 1-based, in file order.
  final int index;

  final PlanTaskStatus status;
  final String text;
}

enum PlanTaskStatus { pending, inProgress, done }

/// The tasks of a plan file's text, in file order, numbering from 1.
///
/// Liberal, because the file is also the model's own writing: a task is a
/// list line whose marker is one of the plan statuses — a bare bullet counts
/// as pending, so a plan written by hand or by an older skill still reads.
/// Prose and other lists in the file are ignored.
List<PlanTask> planTasksFrom(String? text) {
  if (text == null) return const [];
  var index = 0;
  final tasks = <PlanTask>[];
  for (final line in text.split("\n")) {
    final task = _taskLine(line);
    if (task == null) continue;
    tasks.add(PlanTask(
        index: ++index, status: task.status, text: task.text ?? "(untitled task)"));
  }
  return tasks;
}

({PlanTaskStatus status, String? text})? _taskLine(String line) {
  final bullet = RegExp(r"^\s*[-*]\s+(.*)$").firstMatch(line);
  if (bullet == null) return null;
  final rest = bullet.group(1)!.trimLeft();
  final marked = RegExp(r"^\[([ xX~])\]\s*(.*)$").firstMatch(rest);
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
(int done, int total) planProgress(String? text) {
  final tasks = planTasksFrom(text);
  return (tasks.where((t) => t.status == PlanTaskStatus.done).length, tasks.length);
}

/// The first task neither done nor in progress, or null.
PlanTask? planNext(String? text) => planTasksFrom(text)
    .where((t) => t.status == PlanTaskStatus.pending)
    .firstOrNull;

/// [task] as the model named it — the number [planNext] reported, or enough
/// of the task's text to identify it — matched against the plan's tasks.
/// Null where nothing matches; null where the text names several, since the
/// caller refuses rather than guesses.
PlanTask? planFind(String? text, String task) {
  final tasks = planTasksFrom(text);
  final trimmed = task.trim();
  if (trimmed.isEmpty) return null;
  if (RegExp(r"^(\d+)$").hasMatch(trimmed)) {
    final n = int.tryParse(trimmed);
    return n == null || n < 1 || n > tasks.length ? null : tasks[n - 1];
  }
  final needle = trimmed.toLowerCase();
  final hits =
      tasks.where((t) => t.text.toLowerCase().startsWith(needle)).toList();
  return hits.length == 1 ? hits.single : null;
}

/// Add [task] to the end of [section], creating the heading where neither the
/// section nor the file exists yet. The rest of the file stands, since the
/// prose in it is not ours to rewrite.
String planAddTask(String? text, String task, {String? section}) {
  final body = text ?? "";
  final named = section?.trim() ?? "";
  final heading = named.isEmpty ? planDefaultSection : named;
  final line = "- [ ] ${task.trim()}";
  if (body.trim().isEmpty) {
    return "$planHeading\n\n## $heading\n\n$line\n";
  }
  final lines = body.split("\n");
  var at = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == "## $heading") {
      at = i + 1;
      // Past the heading's blank line, then past the tasks already in the
      // section, so the task lands at its end.
      while (at < lines.length && lines[at].trim().isEmpty) {
        at++;
      }
      while (at < lines.length && lines[at].trim().isNotEmpty) {
        at++;
      }
      break;
    }
  }
  // A section nobody wrote yet is opened at the end, so the task is not
  // filed under whatever heading came before it.
  if (at < 0) {
    return "${body.trimRight()}\n\n## $heading\n\n$line\n";
  }
  final insertAt = at.clamp(0, lines.length);
  return [
    ...lines.sublist(0, insertAt),
    line,
    ...lines.sublist(insertAt),
  ].join("\n");
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
    lines[i] = lines[i].replaceFirst(RegExp(r"\[[ xX~]\]"), marker);
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

/// The `plan_next` tool's result.
String planNextResult(PlanTask task, (int done, int total) progress) =>
    "Task ${task.index} of ${progress.$2}: ${task.text}";

/// The `plan_done` tool's result.
String planDoneResult(PlanTask task, (int done, int total) progress) =>
    "Task ${task.index} done: ${task.text}. ${progress.$1} of ${progress.$2} "
    "tasks done.";

/// What `present_plan` puts to the user: one question, the plan on the card
/// beside it, and the answer a verdict.
AskQuestion planApprovalQuestion(String title) => AskQuestion(
      question: title.isEmpty
          ? "Approve this plan?"
          : "Approve the plan \"$title\"?",
      summary: "The plan is on the card beside this message. Go starts the "
          "work; request changes to say what to adjust.",
      options: const [
        AskOption(label: "Go", value: "go"),
        AskOption(
            label: "Request changes",
            value: "changes",
            detail: "The plan needs adjusting before any work starts."),
      ],
    );

/// What `present_plan` reports, from the answers the panel handed back. The
/// verdict rides in the tool result, so the projection words it the same way
/// whether the turn is running now or being read back out of the log.
String planVerdict(List<String?> answers) => switch (answers.firstOrNull) {
      "go" =>
        "Approved: the user pressed Go. Start working through the plan with "
        "$planNextToolName and $planDoneToolName, one task at a time.",
      "changes" =>
        "The user asked for changes. Find out what to adjust, revise the plan "
        "(edit $planFileName, or remove a line and re-add the task with "
        "$planAddToolName), and present it again with the same artifact_id. "
        "Do not start executing until the answer is Go.",
      _ =>
        "No verdict was reached. Finish the turn; do not start executing "
        "the plan.",
    };

/// What `present_plan` is told when its arguments were not its own.
const presentPlanFormatError =
    'The $presentPlanToolName tool takes no required arguments; "title" and '
    '"artifact_id" are optional strings.';

/// A `present_plan` call's arguments: everything is optional, so only a body
/// that is not an object at all fails.
class PresentPlanArgs {
  const PresentPlanArgs({this.title, this.artifactId});

  final String? title;
  final String? artifactId;
}

PresentPlanArgs? presentPlanArgsFrom(String? json) {
  final decoded = decodeArgs(json);
  if (decoded == null) return null;
  String? of(String key) {
    final value = decoded[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  return PresentPlanArgs(title: of("title"), artifactId: of("artifact_id"));
}

/// The page `present_plan` publishes: the plan as one self-contained HTML
/// file for the artifact viewer. The base stylesheet the store injects at
/// publish time styles the elements; [planPageCss] rides under it. Nothing
/// model-written reaches the page unescaped — the plan is the model's prose,
/// and the page opens in the app's viewer.
String planHtml(String plan, {String? title}) {
  final heading = title == null || title.trim().isEmpty ? "Plan" : title.trim();
  final (done, total) = planProgress(plan);
  final body = [
    for (final section in _sections(plan)) ...[
      "<h2>${_escape(section.heading)}</h2>",
      "<ul>",
      for (final task in section.tasks)
        "<li><span class=\"status ${_statusClass(task.status)}\">"
            "${_statusLabel(task.status)}</span>${_escape(task.text)}</li>",
      "</ul>",
    ],
    if (total == 0) "<p>No tasks in the plan yet.</p>",
  ].join("\n");
  return """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>${_escape(heading)}</title>
$planPageCss
</head>
<body>
<main>
<h1>${_escape(heading)}</h1>
<p class="progress">$done of $total tasks done</p>
$body
</main>
</body>
</html>""";
}

final class _PlanSection {
  const _PlanSection(this.heading, this.tasks);
  final String heading;
  final List<PlanTask> tasks;
}

/// The plan's task lines, grouped under the headings they sat under. A task
/// written before any heading sits under the default one. The plan's own
/// first `#` heading — where the tools put `# Plan` — names the artifact's
/// `h1` already, so it opens a section only when a second one never comes;
/// `##` and deeper are section boundaries.
List<_PlanSection> _sections(String plan) {
  final sections = <_PlanSection>[];
  var current = _PlanSection(planDefaultSection, []);
  var titleSeen = false;
  var number = 0;
  void close() {
    if (current.tasks.isNotEmpty) sections.add(current);
  }

  for (final line in plan.split("\n")) {
    final trimmed = line.trim();
    if (trimmed.startsWith("#")) {
      final heading = trimmed.replaceFirst(RegExp(r"^#+\s*"), "").trim();
      if (heading.isEmpty) continue;
      if (!titleSeen && trimmed.startsWith("# ")) {
        titleSeen = true;
        continue;
      }
      close();
      current = _PlanSection(heading, []);
      continue;
    }
    final task = _taskLine(line);
    if (task == null) continue;
    current.tasks.add(PlanTask(
        index: ++number,
        status: task.status,
        text: task.text ?? "(untitled task)"));
  }
  close();
  return sections;
}

String _statusClass(PlanTaskStatus status) => switch (status) {
      PlanTaskStatus.pending => "pending",
      PlanTaskStatus.inProgress => "in-progress",
      PlanTaskStatus.done => "done",
    };

String _statusLabel(PlanTaskStatus status) => switch (status) {
      PlanTaskStatus.pending => "todo",
      PlanTaskStatus.inProgress => "doing",
      PlanTaskStatus.done => "done",
    };

/// The plan page's own styles, after the base stylesheet the viewer injects:
/// the base styles elements, so the chips ride on it rather than fight it.
const planPageCss = """
<style>
.progress {
  font-size: 0.9rem;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--ink-soft);
}
ul { list-style: none; padding: 0; }
li { padding: 0.4rem 0; border-bottom: 1px solid var(--rule-soft); }
.status {
  display: inline-block;
  min-width: 3.5rem;
  text-align: center;
  font-family: var(--font-mono);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  padding: 0.1rem 0.5rem;
  margin-right: 0.6rem;
  border: 1px solid var(--rule-soft);
}
.status.pending { color: var(--ink-soft); }
.status.in-progress { color: var(--accent); border-color: var(--accent); }
.status.done { color: var(--bg); background: var(--ink); border-color: var(--ink); }
</style>""";

String _escape(String text) => const HtmlEscape().convert(text);