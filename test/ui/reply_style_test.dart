import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/widgets/reply_style.dart";
import "package:agent_chat/ui/theme.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// The sheet as a reply is actually drawn with. Built from a pumped context
  /// rather than from `entoliTheme` directly: the text theme's sizes are merged
  /// in under a `MaterialApp`, so a bare `ThemeData` has none and is not the
  /// theme this is ever called with.
  Future<MarkdownStyleSheet> sheetOf(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    await app.pump(tester, const SizedBox(), brightness: brightness);
    return replyStyleSheet(Theme.of(tester.element(find.byType(SizedBox))));
  }

  ColorScheme schemeOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(SizedBox))).colorScheme;

  group("code", () {
    testWidgets("inline code is set in the bundled face, not the platform's",
        (tester) async {
      expect((await sheetOf(tester)).code?.fontFamily, monoFamily);
    });

    // `fromTheme` asks for `cardTheme.color`, which M3 leaves null, so inline
    // code used to be prose in another face and nothing else.
    testWidgets("inline code sits on a surface of its own", (tester) async {
      final sheet = await sheetOf(tester);
      final scheme = schemeOf(tester);

      expect(sheet.code?.backgroundColor, scheme.surfaceContainerHighest);
      expect(sheet.code?.backgroundColor, isNot(scheme.surface));
    });

    testWidgets("that surface follows the palette", (tester) async {
      final light = (await sheetOf(tester)).code?.backgroundColor;
      final dark =
          (await sheetOf(tester, brightness: Brightness.dark)).code?.backgroundColor;

      expect(dark, isNot(light));
    });

    // Mono runs wider than the prose around it, so equal sizes read unequal.
    testWidgets("code is set smaller than the sentence holding it", (tester) async {
      final sheet = await sheetOf(tester);

      expect(sheet.code!.fontSize, lessThan(sheet.p!.fontSize!));
    });
  });

  group("headings", () {
    // `fromTheme` reaches for the display scale, which is a document's, and
    // gives h4 down `bodyLarge` — body size with no weight on it, so the last
    // three levels did not read as headings at all.
    testWidgets("step down and stop at the body", (tester) async {
      final sheet = await sheetOf(tester);
      final scale =
          [sheet.h1!, sheet.h2!, sheet.h3!, sheet.h4!, sheet.h5!, sheet.h6!]
              .map((h) => h.fontSize)
              .toList();

      expect(scale, [21, 18, 16, 14, 14, 14]);
      expect(scale.last, sheet.p!.fontSize);
    });

    testWidgets("every level is set apart by weight, the smallest included",
        (tester) async {
      final sheet = await sheetOf(tester);

      final body = sheet.p!.fontWeight ?? FontWeight.normal;
      for (final h in [sheet.h1!, sheet.h2!, sheet.h3!, sheet.h4!, sheet.h5!, sheet.h6!]) {
        expect(h.fontWeight!.value, greaterThan(body.value));
      }
    });

    // A heading belongs to what follows it, so the air goes above.
    testWidgets("are given room above and none below", (tester) async {
      final sheet = await sheetOf(tester);

      for (final pad in <EdgeInsets>[
        sheet.h1Padding!,
        sheet.h2Padding!,
        sheet.h3Padding!,
        sheet.h4Padding!,
      ]) {
        expect(pad.top, greaterThan(0));
        expect(pad.bottom, 0);
      }
    });
  });

  // The default is five pixels of `dividerColor` across the reply.
  testWidgets("a horizontal rule is a rule rather than a slab", (tester) async {
    final rule = (await sheetOf(tester)).horizontalRuleDecoration! as BoxDecoration;

    expect(rule.border!.top.width, lessThanOrEqualTo(1));
  });

  testWidgets("prose is looser than Material's default", (tester) async {
    expect((await sheetOf(tester)).p!.height, greaterThan(1.43));
  });

  // The OFL asks for the licence to travel with the font. It is registered off
  // an asset and read lazily, so a file left undeclared in pubspec would say
  // nothing at all until someone opened a licence page.
  testWidgets("the bundled font's licence is registered and readable",
      (tester) async {
    registerBundledFontLicences();

    final ours = await LicenseRegistry.licenses
        .where((l) => l.packages.contains(monoFamily))
        .toList();

    expect(ours, hasLength(1));
    final text = ours.single.paragraphs.map((p) => p.text).join("\n");
    expect(text, contains("Roboto Mono"));
    expect(text, contains("SIL OPEN FONT LICENSE"));
  });
}
