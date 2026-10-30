import "../../domain/models.dart";
import "../../domain/shell.dart";
import "llm/llm_client.dart";

/// What decided a call, the tiers that spoke, and the verdict.
typedef Decision = ({
  PermissionSource source,
  List<PermissionTier> tiers,
  PermissionDecision decided,
});

/// A command's outcome as the result of the call that asked for it: one that
/// ran, one that was refused, one that was never reached. The directory the
/// shell was left in rides on it as a fact, and [decision] — what let it run
/// or refused it — beside it.
ToolResult toolRan(
  LlmToolCall call,
  ShellResult result, {
  Decision? decision,
}) => ToolResult(
  callId: call.id,
  returnCode: result.returnCode,
  output: result.output,
  exceptionInfo: result.exceptionInfo,
  cwd: result.cwd,
  jobId: result.jobId,
  decidedBy: decision?.source,
  decidedTier: decision?.tiers ?? const [],
  decided: decision?.decided,
);
