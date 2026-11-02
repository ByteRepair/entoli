import "dart:math" as math;

/// Smooth value noise over the plane: a random value at every lattice point,
/// eased between them, so nearby points are alike and far ones are not. The
/// same seed gives the same field on every run.
class ValueNoise {
  ValueNoise([int seed = 0])
    : _table = List<int>.generate(256, (i) => i)..shuffle(math.Random(seed));

  final List<int> _table;

  int _hash(int x, int y) => _table[(_table[x & 255] + y) & 255];

  double _corner(int x, int y) => _hash(x, y) / 255;

  /// The field at ([x], [y]), from 0 to 1.
  double at(double x, double y) {
    final (x0, y0) = (x.floor(), y.floor());
    final (fx, fy) = (_ease(x - x0), _ease(y - y0));
    final top = _lerp(_corner(x0, y0), _corner(x0 + 1, y0), fx);
    final bottom = _lerp(_corner(x0, y0 + 1), _corner(x0 + 1, y0 + 1), fx);
    return _lerp(top, bottom, fy);
  }

  /// [at] summed over [octaves] layers, each turned, twice the frequency and
  /// half the weight of the one before, normalised back to 0 to 1. A fractional count
  /// fades the last layer in, so detail can grow smoothly along a gradient.
  double fractal(double x, double y, double octaves) {
    var (sum, weight, total) = (0.0, 1.0, 0.0);
    for (var i = 0; i < octaves; i++) {
      // Each layer turned against the last, so the lattice never lines up
      // into the straight runs value noise is known for.
      (x, y) = (2 * (x * _cos - y * _sin) + 17.3, 2 * (x * _sin + y * _cos));
      final share = math.min(1.0, octaves - i) * weight;
      sum += at(x, y) * share;
      total += share;
      weight /= 2;
    }
    return total == 0 ? 0 : sum / total;
  }

  // Quintic rather than cubic: no crease at the lattice lines.
  static double _ease(double t) => t * t * t * (t * (t * 6 - 15) + 10);

  static final _sin = math.sin(0.6), _cos = math.cos(0.6);

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
