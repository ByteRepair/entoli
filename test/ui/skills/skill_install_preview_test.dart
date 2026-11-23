import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;
import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/data/prompts/skill_package.dart";
import "package:agent_chat/ui/skills/skill_install_preview.dart";

import "../../fakes.dart";
import "../../harness.dart";

const _skillMd =
    "---\nname: letterbox\ndescription: frames the reply\n---\n\nFrame it.\n";

/// A home that opens the preview once it is on screen, so the page has a
/// route to pop back to.
class _Launcher extends StatefulWidget {
  const _Launcher();

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        openSkillInstall(context, chatId: "chat-1", installId: "install-1");
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text("chat"));
}

Uint8List stagedPackage() => packageSkillBytes(
  SkillPackage("letterbox", [
    ("SKILL.md", Uint8List.fromList(utf8.encode(_skillMd))),
    ("scripts/run.sh", Uint8List.fromList(utf8.encode("#!/bin/sh\necho\n"))),
  ]),
);

final _installButton = find.widgetWithText(FilledButton, "Install skill");

void main() {
  late FakeChatStore store;
  late TestApp app;

  setUp(() {
    store = FakeChatStore();
    app = TestApp.create(store: store);
  });
  tearDown(() => app.dispose());

  String skillDir({String? project}) =>
      skillDirectory(app.config, "letterbox", project: project);

  testWidgets("a drafted skill is previewed, and installing lands it", (
    tester,
  ) async {
    store.stageSkillInstall("chat-1", "install-1", stagedPackage());
    await app.pump(tester, const _Launcher(), settle: false);
    await pumpUntil(tester, _installButton);

    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("frames the reply"), findsOneWidget);
    expect(find.text("Frame it."), findsOneWidget);
    expect(find.text("scripts/run.sh"), findsOneWidget);

    await tester.tap(_installButton);
    await settleIo(tester, least: 20, tries: 80);

    expect(File(p.join(skillDir(), "SKILL.md")).existsSync(), isTrue);
    expect(File(p.join(skillDir(), "scripts", "run.sh")).existsSync(), isTrue);
    expect(_installButton, findsNothing);
    expect(find.text("chat"), findsOneWidget);
    expect(find.text("Installed letterbox."), findsOneWidget);
  });

  testWidgets("installing over a skill asks first, and Replace replaces", (
    tester,
  ) async {
    final dir = skillDir();
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, "SKILL.md")).writeAsStringSync("old\n");
    File(p.join(dir, "obsolete.sh")).writeAsStringSync("old\n");
    store.stageSkillInstall("chat-1", "install-1", stagedPackage());
    await app.pump(tester, const _Launcher(), settle: false);
    await pumpUntil(tester, _installButton);

    await tester.tap(_installButton);
    await pumpUntil(tester, find.text("Replace"));
    await tester.tap(find.text("Replace"));
    await settleIo(tester, least: 20, tries: 80);

    expect(File(p.join(dir, "obsolete.sh")).existsSync(), isFalse);
    expect(File(p.join(dir, "SKILL.md")).readAsStringSync(), _skillMd);
  });

  testWidgets("the project picked is where the skill lands", (tester) async {
    await io(tester, () => app.repo.createProject("work"));
    store.stageSkillInstall("chat-1", "install-1", stagedPackage());
    await app.pump(tester, const _Launcher(), settle: false);
    await pumpUntil(tester, _installButton);

    await scrollTo(tester, find.text("Global"));
    await tester.tap(find.text("Global"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("work").last);
    await tester.pumpAndSettle();
    await tester.tap(_installButton);
    await settleIo(tester, least: 20, tries: 80);

    expect(
      File(p.join(skillDir(project: "work"), "SKILL.md")).existsSync(),
      isTrue,
    );
    expect(Directory(skillDir()).existsSync(), isFalse);
  });

  testWidgets("a package that cannot be read says so", (tester) async {
    await app.pump(tester, const _Launcher(), settle: false);
    await pumpUntil(tester, find.textContaining("could not be read"));
    expect(_installButton, findsNothing);
  });
}
