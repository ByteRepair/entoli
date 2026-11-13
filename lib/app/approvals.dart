import "../domain/models.dart";
import "../domain/permission.dart" show addDirectoryName;
import "../domain/tool_arg.dart" show stringArg;
import "chat_controller.dart" show TurnDriver;

/// Which answers [approval] is offered beside Deny, which always is: Allow for
/// this call, and the Always answers that write a rule. A this-turn-only
/// answer to a directory grant would lapse at the next turn, so where a rule
/// can be written that is the answer; a mirrored chat keeps Allow, its
/// Always answers being absent.
({bool allow, bool always}) approvalAnswers(
  TurnDriver driver,
  ToolApproval approval,
) => (
  allow: !(driver.rulesWritable && approval.toolName == addDirectoryName),
  always: driver.rulesWritable,
);

/// What the agent says [approval]'s call is for: the `description` it gave
/// the call, its own claim, shown beside the call rather than in its place.
String? approvalPurpose(ToolApproval approval) {
  final text = stringArg(approval.argumentsJson, "description")?.trim();
  return text == null || text.isEmpty ? null : text;
}

extension AnswerApproval on TurnDriver {
  /// Answer [approval]: a standing rule carries the call it is a rule for,
  /// a one-off answer only its id.
  Future<void> answer(ToolApproval approval, ApprovalResponse response) =>
      respondApproval(
        approval.id,
        response,
        approval:
            response == ApprovalResponse.alwaysAllowChat ||
                response == ApprovalResponse.alwaysAllowProject
            ? approval
            : null,
      );
}
