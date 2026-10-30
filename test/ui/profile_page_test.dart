import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/gestures.dart" show kLongPressTimeout;
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/profile/linked_instructions.dart";
import "package:agent_chat/ui/profile/profile_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  String file(String name, String text) {
    final f = File("${app.config.dataDir}/../linked/$name")
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    return f.absolute.path;
  }

  void link(Map<String, dynamic> json) =>
      File(app.config.linkedInstructionsFile)
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(json));

  Map<String, dynamic> linked() =>
      jsonDecode(File(app.config.linkedInstructionsFile).readAsStringSync())
          as Map<String, dynamic>;

  // The rows are a desktop's alone, and the test host says Android. Tall, so
  // the list builds the rows below the profile fields.
  Future<void> desktop(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    useWindow(tester, const Size(1000, 2400));
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets(
    "the linked files are listed, a missing one said, a removed one "
    "unlinked on save",
    (tester) => desktop(tester, () async {
      late String claude, agents;
      await io(tester, () async {
        claude = file("CLAUDE.md", "claude rules");
        agents = file("AGENTS.md", "agents rules");
        link({
          "files": [claude, agents, "/nowhere/GONE.md"],
        });
      });
      await app.pump(tester, const ProfilePage(project: null));
      await settleIo(tester);

      expect(find.text("CLAUDE.md"), findsOneWidget);
      expect(find.text("Not found: /nowhere/GONE.md"), findsOneWidget);

      await tester.ensureVisible(find.text("CLAUDE.md"));
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text("CLAUDE.md"),
            matching: find.byType(ListTile),
          ),
          matching: find.byTooltip("Remove"),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip("Save"));
      await settleIo(tester);

      expect(await io(tester, () async => linked()["files"]), [
        agents,
        "/nowhere/GONE.md",
      ]);
      expect(File(claude).existsSync(), isTrue);
    }),
  );

  testWidgets(
    "a held row drags to a new place",
    (tester) => desktop(tester, () async {
      late String a, b;
      await io(tester, () async {
        a = file("A.md", "a");
        b = file("B.md", "b");
        link({
          "files": [a, b],
        });
      });
      await app.pump(tester, const ProfilePage(project: null));
      await settleIo(tester);
      await tester.ensureVisible(find.text("B.md"));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text("A.md")),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip("Save"));
      await settleIo(tester);

      expect(await io(tester, () async => linked()["files"]), [b, a]);
    }),
  );

  testWidgets(
    "a project switches the user's files off, each on by default",
    (tester) => desktop(tester, () async {
      late String claude;
      await io(tester, () async {
        claude = file("CLAUDE.md", "claude rules");
        File(
          app.config.globalInstructionsFile,
        ).writeAsStringSync("global rules");
        Directory(
          app.config.projectDir(project: "work"),
        ).createSync(recursive: true);
        link({
          "files": [claude],
        });
      });
      await app.pump(tester, const ProfilePage(project: "work"));
      await settleIo(tester);

      expect(find.text("General instructions"), findsNWidgets(2));
      final switches = find.descendant(
        of: find.byType(InstructionFileSwitches),
        matching: find.byType(Switch),
      );
      expect(switches, findsNWidgets(2));
      for (final s in tester.widgetList<Switch>(switches)) {
        expect(s.value, isTrue);
      }

      await tester.ensureVisible(switches.last);
      await tester.tap(switches.last);
      await tester.pump();
      await tester.tap(find.byTooltip("Save"));
      await settleIo(tester);

      expect(await io(tester, () async => linked()["off"]), {
        "work": [claude],
      });
    }),
  );

  testWidgets(
    "only the project's field shows an import, the one that follows it",
    (tester) async {
      bool hintsImport() => tester
          .widgetList<TextField>(find.byType(TextField))
          .any(
            (f) => f.decoration?.hintText?.contains("@docs/style.md") ?? false,
          );

      await app.pump(tester, const ProfilePage(project: null));
      await settleIo(tester);
      expect(hintsImport(), isFalse);

      // Keyed, or the app page's state carries over to the project's.
      await app.pump(
        tester,
        const ProfilePage(key: ValueKey("work"), project: "work"),
      );
      await settleIo(tester);
      expect(hintsImport(), isTrue);
    },
  );

  testWidgets("off a desktop there is nothing to link", (tester) async {
    await app.pump(tester, const ProfilePage(project: null));
    await settleIo(tester);

    expect(find.text("Add instructions file"), findsNothing);
  });
}
