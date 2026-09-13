import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/skills/skill_view.dart";

import "../../harness.dart";

void main() {
  late TestApp app;
  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> openSkill(WidgetTester tester, String name,
      {String? project, String origin = "Bundled"}) async {
    await app.pump(
      tester,
      SkillViewPage(name: name, project: project, origin: origin),
    );
    await settleIo(tester);
  }

  testWidgets("a conforming skill shows its body rendered and its files",
      (tester) async {
    await io(tester,
        () => writeSkill(app, "letterbox", metadata: {"author": "me"}));

    await openSkill(tester, "letterbox");

    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("do letterbox"), findsOneWidget);
    expect(find.textContaining("Do letterbox."), findsOneWidget);
    expect(find.text("Metadata"), findsOneWidget);
    expect(find.textContaining("author: me"), findsOneWidget);
    // No optional spec field is set, so no spec-field row is drawn.
    expect(find.textContaining("License:"), findsNothing);
    expect(find.textContaining("Compatibility:"), findsNothing);
    expect(find.textContaining("Allowed tools:"), findsNothing);
    expect(find.textContaining("Not loaded — does not conform"), findsNothing);
  });

  testWidgets("the optional spec fields are shown where the frontmatter "
      "carries them", (tester) async {
    await io(tester, () async {
      final dir = File(
          "${app.config.promptsDir(CompletionKind.skill)}/letterbox/SKILL.md");
      await dir.create(recursive: true);
      await dir.writeAsString("---\nname: letterbox\ndescription: do letterbox\n"
          "license: MIT\ncompatibility: Requires git\n"
          "allowed-tools: Bash(git:*)\n---\n\nDo letterbox.\n");
    });

    await openSkill(tester, "letterbox");

    expect(find.text("License: MIT"), findsOneWidget);
    expect(find.text("Compatibility: Requires git"), findsOneWidget);
    expect(find.text("Allowed tools: Bash(git:*)"), findsOneWidget);
  });

  testWidgets("a bundled skill's entries come from the embedded const",
      (tester) async {
    await openSkill(tester, "artifact");

    expect(find.text("artifact"), findsOneWidget);
    expect(find.textContaining("Present a result as an interactive HTML"),
        findsOneWidget);
    // skill-creator ships scripts; artifact ships none.
    expect(find.text("Files"), findsNothing);
  });

  testWidgets("a non-conformant folder says the problems, with the way out",
      (tester) async {
    await io(tester, () async {
      final dir = File(
          "${app.config.promptsDir(CompletionKind.skill)}/Bad-Name/SKILL.md");
      await dir.create(recursive: true);
      await dir.writeAsString("---\nname: Bad-Name\n---\n\nBody.\n");
    });

    await openSkill(tester, "Bad-Name", origin: "Not loaded");

    expect(find.textContaining("Not loaded — does not conform"), findsOneWidget);
    expect(find.textContaining("name \"Bad-Name\""), findsOneWidget);
    expect(find.textContaining("no description"), findsOneWidget);
    expect(find.textContaining("Fix the SKILL.md"), findsOneWidget);
  });

  testWidgets("a folder with no SKILL.md is said, not rendered as empty",
      (tester) async {
    await openSkill(tester, "nowhere-at-all", origin: "Not loaded");

    expect(find.textContaining("could not be read"), findsOneWidget);
  });
}