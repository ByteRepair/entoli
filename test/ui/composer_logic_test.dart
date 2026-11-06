import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/quote.dart";
import "package:agent_chat/ui/chat/widgets/composer_controller.dart";
import "package:agent_chat/ui/chat/widgets/composer_embed.dart";
import "package:agent_chat/ui/chat/widgets/composer_logic.dart";

void main() {
  late ComposerController controller;
  late ComposerLogic logic;
  final sent = <(String, List<Attachment>)>[];
  final queued = <String>[];

  setUp(() {
    controller = ComposerController();
    logic = ComposerLogic(controller);
    logic.configure(
      agentSpeaking: false,
      onSend: (text, files) => sent.add((text, files)),
      onQueue: (text, _) => queued.add(text),
      steers: (_) => true,
    );
    sent.clear();
    queued.clear();
  });
  tearDown(() {
    logic.dispose();
    controller.dispose();
  });

  test("the text says which mode it is in", () {
    var shapes = 0;
    logic.addListener(() => shapes++);
    controller.text = "!ls";
    expect(logic.mode, ComposerMode.shell);
    controller.text = "!ls -la";
    expect(
      shapes,
      1,
      reason: "a keystroke that keeps the mode reshapes nothing",
    );
    controller.text = "hello";
    expect(logic.mode, ComposerMode.message);
  });

  test("an embed is counted and alone is worth sending", () {
    controller.append(const QuoteEmbed(Quote("one")));
    expect(logic.embeds, 1);
    expect(logic.canSend.value, isTrue);
  });

  test("Queue is on offer only over a running turn that would be steered", () {
    controller.text = "wait";
    expect(logic.queues.value, isFalse);
    logic.configure(
      agentSpeaking: true,
      onSend: (text, files) => sent.add((text, files)),
      onQueue: (text, _) => queued.add(text),
      steers: (_) => true,
    );
    expect(logic.queues.value, isTrue);
    logic.submit(queue: true);
    expect(queued, ["wait"]);
    expect(sent, isEmpty);
  });

  test("queue falls back to send where Queue is not on offer", () {
    controller.text = "now";
    logic.submit(queue: true);
    expect(sent.single.$1, "now");
    expect(queued, isEmpty);
  });

  test("a new controller is followed", () {
    final other = ComposerController()..text = "!pwd";
    addTearDown(other.dispose);
    logic.controller = other;
    expect(logic.mode, ComposerMode.shell);
    controller.text = "plain";
    expect(logic.mode, ComposerMode.shell, reason: "the old one is let go");
  });

  test("the send button names the callback typed, not every callback's", () {
    String label() =>
        logic.mode.sendLabel(queues: false, callback: logic.callbackLabel);

    controller.text = "/compact";
    expect(logic.mode, ComposerMode.callback);
    expect(label(), "Compact");

    controller.text = "/goal the tests pass";
    expect(label(), "Set goal");
    controller.text = "/goal pause";
    expect(label(), "Pause goal");

    controller.text = "hello";
    expect(logic.callbackLabel, isNull);
    expect(label(), "Send");
  });
}
