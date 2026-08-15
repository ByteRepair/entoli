import "dart:convert";

import "../../domain/ask.dart";
import "../../domain/profile.dart";
import "task_tool.dart";

/// The line that ends a turn. Upstream mini-swe-agent's marker, kept verbatim
/// so a model that has seen the original recognises it.
const submitMarker = "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT";

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

/// Where there is no shell, the submission protocol is unsayable — submitting
/// is itself a command. So the model is told to answer, and the turn ends when
/// it does.
String _withoutShell(String? agentPrompt, {Profile? profile}) => """
You are a helpful assistant.

You are running in a browser, so you have no shell and no filesystem: you
cannot run commands, read files, or change anything. Answer from what you know
and from what the user tells you, and say plainly when something would need a
machine you do not have.

$_asking
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
2. You call a tool at least once: `bash` to run a command, `$taskToolName` to
   delegate a task to a sub-agent, `$askToolName` to put a question to the
   user, `websearch` to search the web, or `webfetch` to read a page.
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

## Finishing a turn

As soon as you have answered the question or completed the task, call the
`bash` tool one last time with `echo $submitMarker` as the whole command, and
nothing else in it. That ends the turn and hands your reply to the user.

Finish the moment you have the answer. Do not keep running commands to look
busy, and do not go looking for more to say. If the question needs no commands
at all, say your answer and finish immediately.

Do not repeat your answer inside that command — the user already sees your
reasoning text.

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
changed does what you meant. Call `bash` with `echo $submitMarker` as soon as
you have an answer for them.""";

/// What the model is told when the model returned no command to run.
String formatError({String? finishReason}) {
  if (finishReason == "length") {
    return "Your previous response hit the output limit before you produced a "
        "tool call, so it was cut off. Be more concise and finish with exactly "
        "one `bash` tool call.";
  }
  return "Every response must call the `bash` tool at least once. Call it with "
      "your command as the argument, for example {\"command\": \"ls -la\"}. "
      "If you are done, run `echo $submitMarker` on its own.";
}

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

/// What a fresh session is told about the conversation it missed.
String transcriptPreamble(String body) => "Earlier in this conversation:\n\n$body";

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
