import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/composer.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/quote.dart";
import "package:agent_chat/ui/chat/widgets/composer_controller.dart";
import "package:agent_chat/ui/chat/widgets/composer_embed.dart";
import "package:agent_chat/ui/chat/widgets/composer_words.dart";

void main() {
  late ComposerController controller;
  late ComposerModel logic;
  final sent = <(String, List<Attachment>)>[];
  final queued = <String>[];
  final picked = <AttachmentKind>[];
  var stopped = 0;
  var voiced = 0;

  setUp(() {
    controller = ComposerController();
    logic = ComposerModel(
      controller,
      pick: (kind) async {
        picked.add(kind);
        return [
          Attachment(
            filename: "${kind.name}.bin",
            mimeType: "a/b",
            bytes: Uint8List(0),
          ),
        ];
      },
    );
    logic.configure(
      agentSpeaking: false,
      onSend: (text, files) => sent.add((text, files)),
      onQueue: (text, _) => queued.add(text),
      steers: (_) => true,
      onAbort: () => stopped++,
      onVoice: () => voiced++,
    );
    sent.clear();
    queued.clear();
    picked.clear();
    stopped = 0;
    voiced = 0;
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
    logic.field = other;
    expect(logic.mode, ComposerMode.shell);
    controller.text = "plain";
    expect(logic.mode, ComposerMode.shell, reason: "the old one is let go");
  });

  test("the send button names the callback typed, not every callback's", () {
    String label() =>
        logic.mode.sendLabel(queues: false, callback: logic.callback);

    controller.text = "/compact";
    expect(logic.mode, ComposerMode.callback);
    expect(label(), "Compact");

    controller.text = "/goal the tests pass";
    expect(label(), "Set goal");
    controller.text = "/goal pause";
    expect(label(), "Pause goal");

    controller.text = "hello";
    expect(logic.callback, isNull);
    expect(label(), "Send");
  });

  group("each action", () {
    test("send and queue are a submit", () async {
      controller.text = "now";
      await logic.run(ComposerAction.send);
      expect(sent.single.$1, "now");
      expect(controller.text, isEmpty);
    });

    test("stop and voice reach the turn's callbacks", () async {
      await logic.run(ComposerAction.stop);
      await logic.run(ComposerAction.voice);
      expect((stopped, voiced), (1, 1));
    });

    test("an attach runs the frontend's picker and attaches", () async {
      await logic.run(ComposerAction.attachImage);
      await logic.run(ComposerAction.attachFile);
      expect(picked, [AttachmentKind.image, AttachmentKind.file]);
      expect(
        [for (final a in logic.attachments) a.filename],
        ["image.bin", "file.bin"],
      );
    });

    test("a skill's trigger goes at the start, once", () async {
      controller.text = "tidy up";
      await logic.run(ComposerAction.insertSkill);
      expect(controller.text, "/tidy up");
      expect(controller.selection.baseOffset, 1);
      await logic.run(ComposerAction.insertSkill);
      expect(controller.text, "/tidy up");
    });

    test("an agent's trigger goes at the caret, a word of its own", () async {
      controller.text = "ask";
      await logic.run(ComposerAction.insertAgent);
      expect(controller.text, "ask @");
      expect(controller.selection.baseOffset, 5);
    });

    test("a new goal heads what is typed", () async {
      controller.text = "  the tests pass";
      await logic.run(ComposerAction.newGoal);
      expect(controller.text, "/goal the tests pass");
      await logic.run(ComposerAction.newGoal);
      expect(controller.text, "/goal the tests pass");
    });
  });
}
