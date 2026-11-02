import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/shell/shell_turn.dart";

/// Records what the native turn surface asked of the turn.
class _Driver implements TurnDriver {
  final answered = <(String, List<String?>)>[];
  final approved = <(String, ApprovalResponse)>[];

  @override
  Future<void> answerQuestions(String requestId, List<String?> answers) async =>
      answered.add((requestId, answers));

  @override
  Future<void> respondApproval(
    String approvalId,
    ApprovalResponse r, {
    ToolApproval? approval,
  }) async => approved.add((approvalId, r));

  @override
  bool get rulesWritable => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Map<String, Map<String, Object?>> sent;
  late _Driver driver;

  setUp(() {
    sent = {};
    driver = _Driver();
  });

  Future<ShellTurnSurfaceState> pump(
    WidgetTester tester,
    ChatViewState view,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellOutboxProvider.overrideWithValue(
            ShellOutbox((concern, map) => sent[concern] = map),
          ),
        ],
        child: MaterialApp(
          home: ShellTurnSurface(view: view, notifier: driver),
        ),
      ),
    );
    return tester.state(find.byType(ShellTurnSurface));
  }

  testWidgets("a question goes out, and its answers come back", (tester) async {
    final surface = await pump(
      tester,
      ChatViewState(
        questions: {
          "reply": [
            const AskRequest(
              id: "ask-1",
              questions: [
                AskQuestion(
                  question: "Which?",
                  options: [
                    AskOption(label: "One"),
                    AskOption(label: "Two"),
                  ],
                ),
              ],
            ),
          ],
        },
      ),
    );
    final question = sent["turn"]!["question"]! as Map;
    expect(question["id"], "ask-1");
    final asked = (question["questions"]! as List).single as Map;
    expect(asked["question"], "Which?");
    expect((asked["options"]! as List).map((o) => (o as Map)["label"]), [
      "One",
      "Two",
    ]);

    await surface.handle("answer", {
      "id": "ask-1",
      "answers": ["Two"],
    });
    expect(driver.answered.single.$1, "ask-1");
    expect(driver.answered.single.$2, ["Two"]);
  });

  testWidgets("an approval goes out with its answers, and one comes back", (
    tester,
  ) async {
    final surface = await pump(
      tester,
      ChatViewState(
        approvals: {
          "reply": [
            const ToolApproval(
              id: "call-1",
              toolName: "bash",
              argumentsText: "ls -la",
            ),
          ],
        },
      ),
    );
    final approval = (sent["turn"]!["approvals"]! as List).single as Map;
    expect(approval["detail"], "ls -la");
    expect(approval["allow"], isTrue);
    expect(approval["chat"], isTrue);

    await surface.handle("approve", {"id": "call-1", "answer": "chat"});
    expect(driver.approved.single, (
      "call-1",
      ApprovalResponse.alwaysAllowChat,
    ));
  });

  testWidgets("nothing waiting sends nothing to draw", (tester) async {
    await pump(tester, ChatViewState());
    expect(sent["turn"]!["question"], isNull);
    expect(sent["turn"]!["approvals"], isEmpty);
  });
}
