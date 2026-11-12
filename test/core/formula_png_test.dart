import "package:agent_chat/app/transcript/formula.dart";
import "package:agent_chat/core/formula_png.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  const style = FormulaStyle(display: false, fontSize: 16, argb: 0xFF000000);

  testWidgets("typesets TeX into a PNG the size it lays out at", (
    tester,
  ) async {
    final image = (await tester.runAsync(
      () => const MathPngRenderer().render(r"\frac{a}{b}", style),
    ))!;
    expect(image.error, isNull);
    // PNG's signature.
    expect(image.png.take(4), [0x89, 0x50, 0x4E, 0x47]);
    expect(image.width, greaterThan(0));
    expect(image.height, greaterThan(0));
    expect(image.baseline, inInclusiveRange(0, image.height));
  });

  testWidgets("says what TeX it could not read, and still draws it", (
    tester,
  ) async {
    final image = (await tester.runAsync(
      () => const MathPngRenderer().render(r"\frac{a", style),
    ))!;
    expect(image.error, isNotNull);
    expect(image.png, isNotEmpty);
  });

  testWidgets("the cache typesets one TeX and style once", (tester) async {
    final counting = _Counting();
    final cached = CachedFormulaRenderer(counting);
    await tester.runAsync(() async {
      await Future.wait([cached.render("x", style), cached.render("x", style)]);
      await cached.render("x", style);
    });
    expect(counting.calls, 1);
    expect(cached.ready("x", style), isNotNull);
  });
}

class _Counting implements FormulaRenderer {
  var calls = 0;

  @override
  Future<FormulaImage> render(String tex, FormulaStyle style) {
    calls++;
    return const MathPngRenderer().render(tex, style);
  }
}
