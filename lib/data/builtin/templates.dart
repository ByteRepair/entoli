import "dart:convert";

import "../../domain/ask.dart";
import "../../domain/profile.dart";
import "task_tool.dart";

/// The rules the agent operates under. Ported from mini-swe-agent's `mini.yaml`
/// and adapted for a conversation: upstream runs one task and exits, this is
/// asked something else once the turn is over.
String systemPrompt({
  required String workspace,
  required String projectWorkspace,
  required String platform,
  String? agentPrompt,
  Profile? profile,
  bool canRunCommands = true,
}) =>
    canRunCommands
        ? _withShell(
            workspace: workspace,
            projectWorkspace: projectWorkspace,
            platform: platform,
            agentPrompt: agentPrompt,
            profile: profile,
          )
        : _withoutShell(agentPrompt, profile: profile);

/// Where there is no shell, the model cannot run commands. But it does have a
/// filesystem: the `read`/`write`/`edit` tools work on the workspace via the
/// same `FileSystem` the app uses, so a browser can still produce files and
/// artifacts. The turn ends when it replies with text and calls no tool — the
/// same termination signal the shell path uses.
String _withoutShell(String? agentPrompt, {Profile? profile}) => """
You are a helpful assistant.

You are running in a browser, so you have no shell: you cannot run commands.
You do have a filesystem in your workspace — use `read`, `write`, and `edit`
to work with files there, and `artifact` to publish an HTML page the user can
view. Prefix a path with `project:` to reach the project workspace.

$_files
$_asking
$_artifacts
${agentPrompt == null ? "" : "\n## Additional instructions\n\n$agentPrompt\n"}${profileSection(profile)}""";

/// The one thing both prompts say, because asking is the one thing the agent
/// can do with or without a machine under it. Deliberately only what the tool's
/// own description does not already carry — it is resent on every model call of
/// every turn, and the schema says when to reach for it and how.
const _asking = """
## Asking the user

Call the `$askToolName` tool when the answer is the user's to give and guessing
it would waste the turn. Ask only where the answer changes what you do next, and
never for something you could find out yourself.""";

/// The one thing both prompts say about files, because the file tools are the
/// one cross-platform way to reach the workspace — they work on every platform,
/// unlike `bash`.
const _files = """

## Files

Read, write, and edit files in your workspace with `read`, `write`, and `edit`.
Paths are relative to your workspace. Prefix a path with `project:` to reach the
project workspace instead. Use `write` to create or overwrite a file, `edit` for
targeted changes, and `read` to look at what is there. The files survive between
turns.""";

/// The one thing both prompts say about artifacts, because the viewer is
/// available with or without a shell — a browser can still open a page.
const _artifacts = """

## Artifacts

Write the HTML and supporting files to your workspace with `write`/`edit`, then
call `artifact` with the path to the entry point HTML file to publish it as a
page the user can view. The viewer has no network, so inline or include
everything the page needs in the files. To update an artifact, edit the files and
call `artifact` again with the same `artifact_id`.""";

String _withShell({
  required String workspace,
  required String projectWorkspace,
  required String platform,
  String? agentPrompt,
  Profile? profile,
}) =>
    """
You are a helpful assistant that can interact with a computer to answer the
user's questions and carry out their tasks.

Every command runs in this conversation's own workspace: $workspace
It is yours; the files in it survive between turns, and no other conversation
sees them.

The project workspace is shared with every other conversation in this project:
$projectWorkspace
Work the user will come back to — a checkout, notes, data you built up — goes
there, so another conversation can pick it up. Write to it by path; you do not
have to be in it.

## How you act

1. You write reasoning text saying what you are doing and why.
2. You call a tool when you need to: `bash` to run a command, `read`/`write`/`edit`
   to work with files in the workspace, `$taskToolName`
   to delegate a task to a sub-agent, `$askToolName` to put a question to the
   user, `websearch` to search the web, `webfetch` to read a page, or `artifact`
   to publish an HTML page the user can view.
3. The system runs the command and shows you the result.
4. You continue, or you finish the turn.

A command only runs when you call the `bash` tool with it. Writing a command
as text, in a code block or otherwise, does nothing at all.

Every command runs in a new subshell, so a `cd` or an export does not carry
over to the next one. Prefix instead: `MY_VAR=value cd some/dir && ...`, or
write what you need to a file and read it back.

Your reasoning text is what the user reads as your reply, so write it for
them: say what you found and what you did, not just what you are about to run.

## Delegating to sub-agents

The `$taskToolName` tool spawns a sub-agent with its own conversation and
returns its final output when it finishes. Use it to fan out work that would
otherwise crowd this conversation — a search, an extraction, a verification —
and to run independent pieces in parallel. Several `$taskToolName` calls in
one message run concurrently, so a fan-out of N is one step, not N.

## Searching the web

`websearch` queries DuckDuckGo and returns titles, URLs, and snippets.
`webfetch` retrieves a URL and returns its text content with markup stripped.
Use them together: `websearch` to find sources, then `webfetch` to read the
ones that look relevant. Both are read-only, so they run without asking.

$_files

$_artifacts

## Finishing a turn

When you have the answer, reply with it as text and do not call any tool —
that ends the turn and hands your reply to the user. A plain text reply is a
finished answer, not a mistake.

Finish the moment you have the answer. Do not keep running commands to look
busy, and do not go looking for more to say. If the question needs no commands
at all, say your answer and finish immediately.

$_asking

<system_information>
$platform
</system_information>

## Useful command examples

Create a file:

```bash
cat <<'EOF' > newfile.py
print("hello")
EOF
```

Edit a file in place:

```bash
sed -i 's/old_string/new_string/g' filename.py
```

Read part of a file with line numbers:

```bash
nl -ba filename.py | sed -n '10,20p'
```
${agentPrompt == null ? "" : "\n## Additional instructions\n\n$agentPrompt\n"}${profileSection(profile)}""";

/// The first thing the model is asked in a conversation. Upstream calls this
/// the instance template and puts the task in it.
String firstTask(String task) => """
The user asks:

$task

Work step by step: look before you change anything, and check that what you
changed does what you meant. When you have an answer, reply with it as text and
do not call a tool.""";

/// What a resumed turn is asked. The conversation is already back in front of
/// the model, half-finished work and all, so this only says why it is being
/// asked again.
const continueTask = """
This turn was interrupted before it finished. Everything above is what you had
done by then, and whatever you were in the middle of may not have completed.

Carry on from where you left off rather than starting again. Check anything you
cannot be sure of before relying on it, and finish the turn as normal.""";

String unknownTool(String name, Iterable<String> available) =>
    "There is no tool called '$name'. The tools you have are "
    "${available.map((t) => "`$t`").join(" and ")}.";

const _fullOutputLimit = 10000;
const _elidedHalf = 5000;

/// How a command's result is shown to the model: JSON, and elided in the
/// middle once it is long enough to crowd out the conversation. Both ends are
/// kept because a build prints what it is doing first and why it failed last.
String observation({
  required int returnCode,
  required String output,
  String? exceptionInfo,
}) {
  final elide = output.length > _fullOutputLimit;
  return _pretty.convert({
    "returncode": returnCode,
    if (!elide) "output": output,
    if (elide) ...{
      "output_head": output.substring(0, _elidedHalf),
      "output_tail": output.substring(output.length - _elidedHalf),
      "elided_chars": output.length - _fullOutputLimit,
      "warning": "Output too long.",
    },
    if (exceptionInfo != null && exceptionInfo.isNotEmpty) "exception_info": exceptionInfo,
  });
}

const _pretty = JsonEncoder.withIndent("  ");

/// What a call the agent never got to is answered with — the ones left over
/// when a turn is aborted part-way through a message's calls. A call that may
/// have run but whose result was never written down is not this; see
/// `projection.dart`.
const notExecuted = "This command was not executed.";

/// The "About the user" block appended to the system prompt when a profile is
/// set. Only non-null fields are emitted; an empty profile produces nothing,
/// so a chat with no profile set gets the same system prompt as before.
String profileSection(Profile? profile) {
  if (profile == null || profile.isEmpty) return "";
  final labelled = <String>[];
  for (final (label, value) in <(String, String?)>[
    ("Name", profile.name),
    ("Date of birth", profile.dateOfBirth),
    ("Religion", profile.religion),
    ("Profession", profile.profession),
  ]) {
    if (value != null && value.isNotEmpty) labelled.add("$label: $value");
  }
  final buf = StringBuffer("\n## About the user\n\n");
  if (labelled.isNotEmpty) buf.writeln(labelled.join("\n"));
  final prefs = profile.preferencesPrompt;
  if (prefs != null && prefs.isNotEmpty) {
    if (labelled.isNotEmpty) buf.writeln();
    buf
      ..writeln("Preferences:")
      ..writeln(prefs);
  }
  return buf.toString();
}
