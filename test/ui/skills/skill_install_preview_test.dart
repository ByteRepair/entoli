import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/data/prompts/skill_package.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/skills/skill_install_preview.dart";

import "../../fakes.dart";
import "../../harness.dart";

const _skillMd =
    "---\nname: letterbox\ndescription: frames the reply\n---\n\nFrame \$ARGUMENTS.\n";

/// A home that pushes the preview page as soon as it is on screen, so the page
/// has a route to pop back to.
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
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const SkillInstallPreviewPage(
            chatId: "chat-1",
            installId: "install-1",
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

Uint8List stagedPackage() => packageSkillBytes(SkillPackage("letterbox", [
      ("SKILL.md", Uint8List.fromList(utf8.encode(_skillMd))),
      ("scripts/run.sh", Uint8List.fromList(utf8.encode("#!/bin/sh\necho\n"))),
    ]));

/// The page's Install button, as distinct from the AppBar's "Install skill" title.
final _installButton = find.widgetWithText(FilledButton, "Install skill");

void main() {
  testWidgets("a staged skill is previewed, and installing lands it on disk",
      (tester) async {
    final store = FakeChatStore();
    final app = TestApp.create(store: store);
    addTearDown(app.dispose);

    store.stageSkillInstall("chat-1", "install-1", stagedPackage());

    await app.pump(tester, const _Launcher(), settle: false);
    await pumpUntil(tester, _installButton);

    // The name, the description, and the files that ship beside SKILL.md.
    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("frames the reply"), findsOneWidget);
    expect(find.text("scripts/run.sh"), findsOneWidget);

    await tester.tap(_installButton);
    await settleIo(tester, least: 20, tries: 80);

    // The install reached the user's skills directory, files and all.
    final dir = p.join(app.config.promptsDir(CompletionKind.skill), "letterbox");
    expect(File(p.join(dir, "SKILL.md")).existsSync(), isTrue);
    expect(File(p.join(dir, "scripts", "run.sh")).existsSync(), isTrue);

    // The page went back once it had installed.
    expect(_installButton, findsNothing);
  });

  testWidgets("a package the store cannot hand over says so", (tester) async {
    final store = FakeChatStore();
    final app = TestApp.create(store: store);
    addTearDown(app.dispose);

    // Nothing staged under this id.
    await app.pump(tester, const _Launcher(), settle: false);
    await pumpUntil(tester, find.textContaining("could not be read"));

    expect(_installButton, findsNothing);
  });

  testWidgets("installing over an existing skill asks first, and Replace replaces",
      (tester) async {
    final store = FakeChatStore();
    final app = TestApp.create(store: store);
    addTearDown(app.dispose);

    // A skill already installed under the same name, with a file the new
    // packaging would drop.
    final dir = p.join(app.config.promptsDir(CompletionKind.skill), "letterbox");
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, "SKILL.md")).writeAsStringSync("old\n");
    File(p.join(dir, "obsolete.sh")).writeAsStringSync("old\n");

    store.stageSkillInstall("chat-1", "install-1", stagedPackage());

    await app.pump(tester, const _Launcher(), settle: false);
    await pumpUntil(tester, _installButton);

    await tester.tap(_installButton);
    await pumpUntil(tester, find.text("Replace"));

    await tester.tap(find.text("Replace"));
    await settleIo(tester);

    // The replace was wholesale: the dropped file is gone, the rest rewritten.
    expect(File(p.join(dir, "obsolete.sh")).existsSync(), isFalse);
    expect(File(p.join(dir, "SKILL.md")).readAsStringSync(), _skillMd);
    expect(File(p.join(dir, "scripts", "run.sh")).existsSync(), isTrue);
  });
}
