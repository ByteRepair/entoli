import "dart:convert";
import "dart:io";

import "package:flutter/gestures.dart" show kLongPressTimeout;
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/tone.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/profile/profile_page.dart";
import "package:agent_chat/ui/widgets/prompt_field.dart";
import "package:agent_chat/ui/widgets/text_file_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// The page pushed over a host, so Save has somewhere to go back to.
  Future<void> open(WidgetTester tester, {String? project}) async {
    // Tall enough for the whole page, the list being lazy.
    useWindow(tester, const Size(800, 2400));
    await app.pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => openProfile(context, project: project),
            child: const Text("host"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("host"));
    await settleIo(tester);
  }

  Finder field(String label) => find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(Column)),
    matching: find.byType(TextField),
  );

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip("Save"));
    await settleIo(tester, least: 12);
  }

  testWidgets("what is typed is saved whole, and the page goes", (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(field("Name").first, "Ada");

    await tester.tap(find.text("Edit general instructions"));
    await tester.pumpAndSettle();
    // A prose field, which wraps.
    final editor = tester.widget<TextField>(
      find.descendant(
        of: find.byType(PromptPage),
        matching: find.byType(TextField),
      ),
    );
    expect(editor.maxLines, isNull);
    await tester.enterText(find.byType(TextField).last, "Be brief.");
    await tester.tap(find.text("Save").last);
    await tester.pumpAndSettle();
    expect(find.text("Be brief."), findsOneWidget);

    await tester.tap(find.text(Tone.none.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Tone.values.last.label).last);
    await tester.pumpAndSettle();

    await save(tester);
    expect(find.byType(ProfilePage), findsNothing);
    final settings = app.container.read(appSettingsProvider);
    expect(settings.profile?.name, "Ada");
    expect(settings.tone, Tone.values.last);
    expect(
      File(app.config.globalInstructionsFile).readAsStringSync(),
      "Be brief.",
    );
  });

  testWidgets("leaving with an edit asks first", (tester) async {
    await open(tester);
    await tester.enterText(field("Name").first, "Ada");
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text("Discard changes"), findsOneWidget);
  });

  testWidgets("a date of birth not written as a date is refused", (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(field("Date of birth").first, "last tuesday");
    await save(tester);
    expect(find.textContaining("YYYY-MM-DD"), findsWidgets);
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(app.container.read(appSettingsProvider).profile, isNull);
  });

  testWidgets("the date of birth can be picked", (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip("Pick date"));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text("OK"));
    await tester.pumpAndSettle();
    final text = tester
        .widget<TextField>(field("Date of birth").first)
        .controller!
        .text;
    expect(DateTime.tryParse(text), isNotNull);
  });

  testWidgets("a project's page is its instructions and its own answers", (
    tester,
  ) async {
    await io(tester, () => app.repo.createProject("work"));
    await open(tester, project: "work");
    expect(find.text("Project instructions"), findsOneWidget);
    expect(find.text("Name"), findsNothing);
    expect(find.textContaining(Tone.none.label), findsWidgets);
  });

  testWidgets(
    "a desktop links files in order, a missing one said and not opened",
    (tester) async {
      final claude = File("${app.config.dataDir}/../linked/CLAUDE.md")
        ..createSync(recursive: true)
        ..writeAsStringSync("rules");
      File(app.config.linkedInstructionsFile)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            "files": [claude.absolute.path, "/nowhere/GONE.md"],
          }),
        );
      await open(tester);
      expect(find.text("CLAUDE.md"), findsOneWidget);
      expect(find.text("Not found: /nowhere/GONE.md"), findsOneWidget);

      await tester.tap(find.text("GONE.md"));
      await settleIo(tester);
      expect(find.byType(TextFilePage), findsNothing);

      // Held, then dragged above the first.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text("GONE.md")),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      await save(tester);
      final saved = await io(
        tester,
        () => app.container.read(linkedInstructionsStoreProvider).load(),
      );
      expect(saved.files, ["/nowhere/GONE.md", claude.absolute.path]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets("a picked file is linked, and a linked file opens in the app", (
    tester,
  ) async {
    final notes = File("${app.config.dataDir}/../linked/NOTES.md")
      ..createSync(recursive: true)
      ..writeAsStringSync("notes");
    app.folders.scriptedFiles = [notes.absolute.path];
    await open(tester);
    await tester.tap(find.text("Link files…"));
    await settleIo(tester);
    await tester.tap(find.text("NOTES.md"));
    await settleIo(tester);
    expect(find.byType(TextFilePage), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets("a project switches the user's files, and a row opens its file", (
    tester,
  ) async {
    File(app.config.globalInstructionsFile)
      ..createSync(recursive: true)
      ..writeAsStringSync("rules");
    await io(tester, () => app.repo.createProject("work"));
    await open(tester, project: "work");

    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    await save(tester);
    final saved = await io(
      tester,
      () => app.container.read(linkedInstructionsStoreProvider).load(),
    );
    expect(saved.off["work"], {app.config.globalInstructionsFile});

    await open(tester, project: "work");
    await tester.tap(find.text(app.config.globalInstructionsFile));
    await settleIo(tester);
    expect(find.byType(TextFilePage), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets("off a desktop there is nothing to link", (tester) async {
    await open(tester);
    expect(find.text("Linked files"), findsNothing);
  });
}
