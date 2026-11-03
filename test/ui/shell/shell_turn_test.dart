import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/shell/shell_turn.dart";

import "fake_native_shell.dart";

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
  late FakeNativeShell shell;
  late _Driver driver;

  setUp(() {
    shell = FakeNativeShell.install();
    driver = _Driver();
  });

  Future<ShellTurnSurfaceState> pump(
    WidgetTester tester,
    ChatViewState view,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
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
    final question = shell.lastTurn!.question!;
    expect(question.id, "ask-1");
    final asked = question.questions.single;
    expect(asked.question, "Which?");
    expect(asked.options.map((o) => o.label), ["One", "Two"]);

    await surface.answer("ask-1", ["Two"]);
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
    final approval = shell.lastTurn!.approvals.single;
    expect(approval.detail, "ls -la");
    expect(approval.allow, isTrue);
    expect(approval.chat, isTrue);

    await surface.approve("call-1", ApprovalAnswer.chat);
    expect(driver.approved.single, (
      "call-1",
      ApprovalResponse.alwaysAllowChat,
    ));
  });

  testWidgets("nothing waiting sends nothing to draw", (tester) async {
    await pump(tester, ChatViewState());
    expect(shell.lastTurn!.question, isNull);
    expect(shell.lastTurn!.approvals, isEmpty);
  });
}
