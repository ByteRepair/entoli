import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/noise.dart";

void main() {
  test("the same seed is the same field, within 0 to 1 and smooth", () {
    final a = ValueNoise(3);
    final b = ValueNoise(3);
    for (var i = 0; i < 200; i++) {
      final (x, y) = (i * 0.37 - 20, i * 0.11 - 5);
      expect(a.at(x, y), b.at(x, y));
      expect(a.fractal(x, y, 3.5), inInclusiveRange(0, 1));
      // Eased between lattice points: a small step is a small change.
      expect((a.at(x, y) - a.at(x + 0.01, y)).abs(), lessThan(0.05));
    }
  });

  test("a fractional octave fades the next layer in", () {
    final n = ValueNoise();
    expect(n.fractal(1.3, 2.7, 2.0001), closeTo(n.fractal(1.3, 2.7, 2), 1e-4));
    expect(n.fractal(1.3, 2.7, 0), 0);
  });
}
