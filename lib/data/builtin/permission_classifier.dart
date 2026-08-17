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
  }) async {
    final prompt = _classifierPrompt(toolName, argumentsJson, workspace: workspace);
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

  /// The first word that matches a decision, case-insensitive. Anything the
  /// model says that does not start with allow/ask/deny is treated as ask.
  static PermissionDecision _parse(String? answer) {
    if (answer == null || answer.isEmpty) return PermissionDecision.ask;
    final first = answer.split(RegExp(r"\s+")).first;
    return switch (first) {
      "allow" => PermissionDecision.allow,
      "deny" => PermissionDecision.deny,
      _ => PermissionDecision.ask,
    };
  }

  static const _systemPrompt = """
You are a permission classifier. Given a tool call, decide whether it is safe
to run without asking the user.

Reply with exactly one word: allow, ask, or deny.

allow: the call is safe to run. It only reads, checks, or fetches information.
Examples: ls, cat, pwd, git status, git log, grep, find, wc, head, tail, echo,
flutter analyze, dart test, cargo check, npm run, python -c, curl (GET),
websearch, webfetch of a public http/https URL.

deny: the call is dangerous or destructive and must not run under any
circumstances. Examples: rm -rf, git push --force, git push -f, dd, mkfs,
shred, :(){:|:&};:, chmod -R 777 on system paths, any command that writes
outside the workspace, webfetch of non-http(s) URLs, localhost, or internal
IP addresses (127.x, 10.x, 192.168.x, 169.254.x).

ask: the call is neither clearly safe nor clearly dangerous, or it modifies
state in a way the user should confirm. Examples: rm, mv, cp to a path outside
the workspace, git commit, git push, npm install, pip install, apt, brew,
docker, any network mutation (POST, PUT, DELETE), curl to a non-GET endpoint,
kill, pkill, write to a file outside the workspace.
""";

  static String _classifierPrompt(
    String toolName,
    String argumentsJson, {
    required String workspace,
  }) {
    final args = _pretty(argumentsJson, toolName);
    return "Tool: $toolName\nArguments: $args\nWorkspace: $workspace";
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