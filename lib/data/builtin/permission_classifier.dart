import "../../domain/permission.dart";
import "../../domain/tool_arg.dart";
import "llm/llm_client.dart";

/// One-shot LLM classification of a tool call. Sends the tool name and its
/// arguments to a configured model with a system prompt of allow/ask/deny
/// rules, and reads back a single word. No tools, no session, no retries —
/// the agent's turn is waiting on this, so it has to be fast.
///
/// A timeout or any failure falls back to [PermissionDecision.ask]: the safe
/// answer is to escalate to the user rather than run or refuse silently.
class LlmClassifier implements PermissionClassifier {
  LlmClassifier({required this.client, required this.model});

  final LlmClient client;
  final String model;

  static const _timeout = Duration(seconds: 10);

  @override
  Future<PermissionDecision> classify(
    String toolName,
    String argumentsJson, {
    required String workspace,
    List<String> alsoWritable = const [],
  }) async {
    final prompt = _classifierPrompt(toolName, argumentsJson,
        workspace: workspace, alsoWritable: alsoWritable);
    try {
      final chunks = await client
          .stream([
            LlmMessage(role: LlmRole.system, text: _systemPrompt),
            LlmMessage(role: LlmRole.user, text: prompt),
          ], model: model)
          .timeout(_timeout)
          .toList();
      final answer = chunks
          .whereType<LlmCompletion>()
          .lastOrNull
          ?.message
          .text
          .trim()
          .toLowerCase();
      return _parse(answer);
    } catch (_) {
      return PermissionDecision.ask;
    }
  }

  /// The first word, case-insensitive and without punctuation ("Allow." is
  /// allow). Anything that does not start with allow/deny is ask.
  static PermissionDecision _parse(String? answer) {
    final first = RegExp(r"[a-z]+").firstMatch(answer ?? "")?.group(0);
    return switch (first) {
      "allow" => PermissionDecision.allow,
      "deny" => PermissionDecision.deny,
      _ => PermissionDecision.ask,
    };
  }

  static const _systemPrompt = """
You are a permission classifier. Decide whether a tool call is safe to run
without asking the user. The workspace path below is the folder the
conversation may write to freely; any "Also writable" paths below it are
granted the same, so a write inside one is a workspace write.

Reply with exactly one word: allow, ask, or deny.

allow: the call reads something, or writes only inside the workspace. Reading
anywhere is safe: ls, cat, pwd, git status, git log, git diff, grep, find, wc,
head, tail, echo, and reading any file on the machine. A script — python,
magick, pdftotext, gcc — that only produces its files in the workspace is a
workspace write: allow it. Builds, tests and analysers are reads and workspace
writes: flutter analyze, dart test, cargo check, npm run. curl or webfetch of
a public http/https URL with a GET is a read.

ask: the call modifies anything outside the workspace, installs something, or
you are not sure. This includes the machine temp directory /tmp, the machine
home, and every absolute path past the workspace: a script that writes its
output to /tmp is ask, not allow. Also ask: pip install, npm install, apt,
brew, docker, git commit, git push, kill, pkill, curl or webfetch that
mutates (POST, PUT, DELETE), writing to a file outside the workspace.

deny: the call is irreversible or system-wide destruction, and must never run.
rm -rf on a system path, dd, mkfs, shred, fork bombs, chmod -R 777 on system
paths, git push --force. Deny is not a stronger ask: it is only for commands
that must never run. A write you are merely unsure about is ask.
""";

  static String _classifierPrompt(
    String toolName,
    String argumentsJson, {
    required String workspace,
    List<String> alsoWritable = const [],
  }) {
    final args = _pretty(argumentsJson, toolName);
    return "Tool: $toolName\nArguments: $args\nWorkspace: $workspace"
        "${alsoWritable.isEmpty ? "" : "\nAlso writable: ${alsoWritable.join(", ")}"}";
  }

  /// Render the arguments as something the model can read. A bash command is
  /// shown plainly; a webfetch URL is shown as the URL; anything else falls
  /// back to the raw JSON.
  static String _pretty(String argumentsJson, String toolName) {
    final key = switch (toolName) {
      "bash" => "command",
      "webfetch" => "url",
      _ => null,
    };
    if (key == null) return argumentsJson;
    return stringArg(argumentsJson, key) ?? argumentsJson;
  }
}