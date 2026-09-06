import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/widgets/reply_style.dart";
import "package:agent_chat/ui/fonts.dart";

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

  // `fromTheme` sets the face from `monospace` and asks for `cardTheme.color`
  // as a background, which M3 leaves null — so inline code was the sentence in
  // another face and nothing else. Mono also runs wider than the prose beside
  // it, so an equal size reads as a larger one.
  testWidgets("inline code is a bundled face on a surface, set smaller",
      (tester) async {
    final sheet = await sheetOf(tester);
    final scheme = Theme.of(tester.element(find.byType(SizedBox))).colorScheme;

    expect(sheet.code?.fontFamily, monoFamily);
    expect(sheet.code?.backgroundColor, scheme.surfaceContainerHighest);
    expect(sheet.code!.fontSize, lessThan(sheet.p!.fontSize!));
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

  // A list is as much prose as a paragraph, and is the shape a reply most
  // often takes. `fromTheme` hands all four of these plain `bodyMedium`.
  testWidgets("every prose element is looser than Material's default",
      (tester) async {
    final sheet = await sheetOf(tester);

    for (final style in [sheet.p!, sheet.listBullet!, sheet.blockquote!, sheet.tableBody!]) {
      expect(style.height, greaterThan(1.43));
    }
  });

  // The OFL asks for the licence to travel with the font. It is registered off
  // an asset and read lazily, so a file left undeclared in pubspec would say
  // nothing at all until someone opened a licence page. The name in the text
  // is asserted so a pair swapped in fonts.dart cannot pass.
  testWidgets("the bundled fonts' licences are registered and readable",
      (tester) async {
    registerBundledFontLicences();

    final all = await LicenseRegistry.licenses.toList();
    for (final (family, name) in const [
      (monoFamily, "Roboto Mono"),
      (displayFamily, "Playfair Display"),
      (bodyFamily, "Source Serif 4"),
    ]) {
      final ours = all.where((l) => l.packages.contains(family)).toList();

      expect(ours, hasLength(1), reason: family);
      final text = ours.single.paragraphs.map((p) => p.text).join("\n");
      expect(text, contains(name), reason: family);
      expect(text, contains("SIL OPEN FONT LICENSE"), reason: family);
    }
  });
}
