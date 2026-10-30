import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/turn_recorder.dart";

void main() {
  test("a banner is recorded asked and superseded with the answer", () async {
    final written = <List<ChatRecord>>[];
    final recorder = TurnRecorder(
      append: (records) async => written.add(records),
    );
    recorder.open("reply-1");
    recorder.handle(
      const ApprovalRequestEvent(
        ToolApproval(id: "a-1", toolName: "bash", argumentsText: "git status"),
      ),
    );
    recorder.recordApprovalAnswer("a-1", "alwaysAllowProject");
    await recorder.close();

    final parts = [
      for (final batch in written)
        for (final r in batch)
          if (r is PartRecord) r.part,
    ];
    final approvals = parts.whereType<ApprovalPart>().toList();
    expect(approvals, hasLength(2), reason: "the answer supersedes in place");
    expect(approvals.first.answer, "asked");
    expect(approvals.last.answer, "alwaysAllowProject");
    expect(approvals.last.toolName, "bash");
    expect(approvals.last.argumentsText, "git status");
  });

  test("the approval part reads back from the log", () {
    final part =
        MessagePart.fromJson(
              MessagePart.approval(
                approvalId: "a-2",
                toolName: "bash",
                argumentsText: "writing /x",
                deniedDirs: const ["/x"],
                answer: "alwaysAllowChat",
              ).toJson(),
            )
            as ApprovalPart;
    expect(part.approvalId, "a-2");
    expect(part.deniedDirs, ["/x"]);
    expect(part.answer, "alwaysAllowChat");
  });
}
