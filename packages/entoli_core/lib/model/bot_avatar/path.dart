// Restricted SVG path geometry: parser, normaliser and flattener. A port of
// Open Bot Avatar's `path.ts` (MIT, see the licence registered with it).
//
// Accepts the command set M L H V C S Q T A Z, absolute and relative, and
// nothing else. A parsed path is re-serialised from numbers, so nothing a
// model wrote is ever echoed back as it was written.
import "dart:math" as math;
import "dart:typed_data";

/// A point in the avatar's 0..100 box.
typedef Pt = (double, double);

/// A closed polygon, its last point joined back to its first.
typedef Poly = List<Pt>;

/// One absolute segment of a normalised path.
sealed class Segment {
  const Segment();
}

final class MoveTo extends Segment {
  const MoveTo(this.x, this.y);
  final double x, y;
}

final class LineTo extends Segment {
  const LineTo(this.x, this.y);
  final double x, y;
}

final class CubicTo extends Segment {
  const CubicTo(this.x1, this.y1, this.x2, this.y2, this.x, this.y);
  final double x1, y1, x2, y2, x, y;
}

final class QuadTo extends Segment {
  const QuadTo(this.x1, this.y1, this.x, this.y);
  final double x1, y1, x, y;
}

final class ArcTo extends Segment {
  const ArcTo(
    this.rx,
    this.ry,
    this.rotation,
    this.large,
    this.sweep,
    this.x,
    this.y,
  );
  final double rx, ry, rotation;
  final bool large, sweep;
  final double x, y;
}

final class Close extends Segment {
  const Close();
}

/// A path the contract refuses, and why.
class PathError implements Exception {
  const PathError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// How much path a definition may carry.
abstract final class PathLimits {
  static const maxChars = 6000;
  static const maxSegments = 400;
  static const maxSubpaths = 16;
  static const coordMin = -20.0;
  static const coordMax = 120.0;
}

const _argCount = {
  "M": 2,
  "L": 2,
  "H": 1,
  "V": 1,
  "C": 6,
  "S": 4,
  "Q": 4,
  "T": 2,
  "A": 7,
  "Z": 0,
};

final _bad = RegExp(r"[^MmLlHhVvCcSsQqTtAaZz0-9.,eE+\-\s]");
final _token = RegExp(
  r"([MmLlHhVvCcSsQqTtAaZz])|([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|([\s,]+)",
);

List<Object> _tokenize(String d) {
  final bad = _bad.firstMatch(d);
  if (bad != null) {
    throw PathError(
      'unsupported character "${bad[0]}" (allowed commands: '
      "M L H V C S Q T A Z)",
    );
  }
  final tokens = <Object>[];
  var i = 0;
  while (i < d.length) {
    final m = _token.matchAsPrefix(d, i);
    if (m == null || m.end == i) {
      final end = math.min(d.length, i + 12);
      throw PathError('cannot parse path near "${d.substring(i, end)}"');
    }
    if (m[1] != null) {
      tokens.add(m[1]!);
    } else if (m[2] != null) {
      tokens.add(double.parse(m[2]!));
    }
    i = m.end;
  }
  return tokens;
}

/// Parse [d] into absolute M/L/C/Q/A/Z segments. Throws [PathError].
List<Segment> parsePath(String d) {
  if (d.trim().isEmpty) throw const PathError("path is empty");
  if (d.length > PathLimits.maxChars) {
    throw const PathError("path longer than ${PathLimits.maxChars} characters");
  }
  final tokens = _tokenize(d);
  final out = <Segment>[];
  var i = 0;
  var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0;
  Pt? prevC, prevQ;
  var cmd = "";
  var subpaths = 0;
  var open = false;

  while (i < tokens.length) {
    final t = tokens[i];
    if (t is String) {
      cmd = t;
      i++;
      if (cmd == "Z" || cmd == "z") {
        if (!open) throw const PathError("Z without an open subpath");
        out.add(const Close());
        cx = sx;
        cy = sy;
        prevC = prevQ = null;
        open = false;
        continue;
      }
    } else if (cmd.isEmpty) {
      throw const PathError("path must start with M");
    } else if (cmd == "Z" || cmd == "z") {
      throw const PathError("numbers after Z");
    }
    final up = cmd.toUpperCase();
    final rel = cmd != up;
    if (out.isEmpty && up != "M") {
      throw const PathError("path must start with M");
    }
    final n = _argCount[up]!;
    final args = <double>[];
    for (var k = 0; k < n; k++) {
      final v = i + k < tokens.length ? tokens[i + k] : null;
      if (v is! double) throw PathError("command $cmd expects $n numbers");
      if (!v.isFinite) throw const PathError("non-finite number");
      args.add(v);
    }
    i += n;
    final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
    Pt? nextC, nextQ;
    switch (up) {
      case "M":
        // An implicit close keeps the fill semantics explicit.
        if (open) out.add(const Close());
        cx = args[0] + ox;
        cy = args[1] + oy;
        sx = cx;
        sy = cy;
        out.add(MoveTo(cx, cy));
        subpaths++;
        open = true;
        // Pairs after a move are implicit line-tos.
        cmd = rel ? "l" : "L";
      case "L":
        cx = args[0] + ox;
        cy = args[1] + oy;
        out.add(LineTo(cx, cy));
      case "H":
        cx = args[0] + ox;
        out.add(LineTo(cx, cy));
      case "V":
        cy = args[0] + oy;
        out.add(LineTo(cx, cy));
      case "C":
        final s = CubicTo(
          args[0] + ox,
          args[1] + oy,
          args[2] + ox,
          args[3] + oy,
          args[4] + ox,
          args[5] + oy,
        );
        out.add(s);
        nextC = (s.x2, s.y2);
        cx = s.x;
        cy = s.y;
      case "S":
        final x1 = prevC != null ? 2 * cx - prevC.$1 : cx;
        final y1 = prevC != null ? 2 * cy - prevC.$2 : cy;
        final s = CubicTo(
          x1,
          y1,
          args[0] + ox,
          args[1] + oy,
          args[2] + ox,
          args[3] + oy,
        );
        out.add(s);
        nextC = (s.x2, s.y2);
        cx = s.x;
        cy = s.y;
      case "Q":
        final s = QuadTo(
          args[0] + ox,
          args[1] + oy,
          args[2] + ox,
          args[3] + oy,
        );
        out.add(s);
        nextQ = (s.x1, s.y1);
        cx = s.x;
        cy = s.y;
      case "T":
        final x1 = prevQ != null ? 2 * cx - prevQ.$1 : cx;
        final y1 = prevQ != null ? 2 * cy - prevQ.$2 : cy;
        final s = QuadTo(x1, y1, args[0] + ox, args[1] + oy);
        out.add(s);
        nextQ = (x1, y1);
        cx = s.x;
        cy = s.y;
      case "A":
        final [rx, ry, rot, la, sw, ...] = args;
        if (rx < 0 || ry < 0) {
          throw const PathError("arc radii must be non-negative");
        }
        if ((la != 0 && la != 1) || (sw != 0 && sw != 1)) {
          throw const PathError(
            "arc flags must be 0 or 1, written as separate numbers",
          );
        }
        cx = args[5] + ox;
        cy = args[6] + oy;
        out.add(ArcTo(rx, ry, rot, la == 1, sw == 1, cx, cy));
      default:
        throw PathError("unsupported command $cmd");
    }
    prevC = nextC;
    prevQ = nextQ;
    if (out.length > PathLimits.maxSegments) {
      throw const PathError("more than ${PathLimits.maxSegments} segments");
    }
  }
  if (open) out.add(const Close());
  if (subpaths > PathLimits.maxSubpaths) {
    throw const PathError("more than ${PathLimits.maxSubpaths} subpaths");
  }
  for (final s in out) {
    for (final v in _coordinates(s)) {
      if (v < PathLimits.coordMin || v > PathLimits.coordMax) {
        throw PathError("coordinate ${_fmt(v)} far outside the 0..100 viewBox");
      }
    }
  }
  return out;
}

List<double> _coordinates(Segment s) => switch (s) {
  MoveTo(:final x, :final y) || LineTo(:final x, :final y) => [x, y],
  CubicTo(:final x1, :final y1, :final x2, :final y2, :final x, :final y) => [
    x1,
    y1,
    x2,
    y2,
    x,
    y,
  ],
  QuadTo(:final x1, :final y1, :final x, :final y) => [x1, y1, x, y],
  ArcTo(:final rx, :final ry, :final x, :final y) => [rx, ry, x, y],
  Close() => const [],
};

String _fmt(double n) {
  final r = (n * 100).round() / 100;
  if (r == r.truncateToDouble()) return r.toInt().toString();
  return r.toString();
}

/// Compact absolute serialisation, built from the parsed numbers alone.
String serializePath(List<Segment> segs) {
  final b = StringBuffer();
  for (final s in segs) {
    switch (s) {
      case MoveTo(:final x, :final y):
        b.write("M${_fmt(x)} ${_fmt(y)}");
      case LineTo(:final x, :final y):
        b.write("L${_fmt(x)} ${_fmt(y)}");
      case CubicTo(
        :final x1,
        :final y1,
        :final x2,
        :final y2,
        :final x,
        :final y,
      ):
        b.write(
          "C${_fmt(x1)} ${_fmt(y1)} ${_fmt(x2)} ${_fmt(y2)} "
          "${_fmt(x)} ${_fmt(y)}",
        );
      case QuadTo(:final x1, :final y1, :final x, :final y):
        b.write("Q${_fmt(x1)} ${_fmt(y1)} ${_fmt(x)} ${_fmt(y)}");
      case ArcTo():
        b.write(
          "A${_fmt(s.rx)} ${_fmt(s.ry)} ${_fmt(s.rotation)} "
          "${s.large ? 1 : 0} ${s.sweep ? 1 : 0} ${_fmt(s.x)} ${_fmt(s.y)}",
        );
      case Close():
        b.write("Z");
    }
  }
  return b.toString();
}

/// An endpoint arc as sampled points (SVG implementation notes, F.6.5).
void _sampleArc(double x0, double y0, ArcTo s, List<Pt> out) {
  var rx = s.rx, ry = s.ry;
  final x = s.x, y = s.y;
  if (rx == 0 || ry == 0 || (x0 == x && y0 == y)) {
    out.add((x, y));
    return;
  }
  final phi = s.rotation * math.pi / 180;
  final cos = math.cos(phi), sin = math.sin(phi);
  final dx = (x0 - x) / 2, dy = (y0 - y) / 2;
  final x1p = cos * dx + sin * dy, y1p = -sin * dx + cos * dy;
  rx = rx.abs();
  ry = ry.abs();
  final lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
  if (lambda > 1) {
    final k = math.sqrt(lambda);
    rx *= k;
    ry *= k;
  }
  final num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
  final den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  var coef = math.sqrt(math.max(0, num / den));
  if (s.large == s.sweep) coef = -coef;
  final cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx;
  final cx = cos * cxp - sin * cyp + (x0 + x) / 2;
  final cy = sin * cxp + cos * cyp + (y0 + y) / 2;
  double ang(double ux, double uy, double vx, double vy) =>
      math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
  final t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
  var dt = ang(
    (x1p - cxp) / rx,
    (y1p - cyp) / ry,
    (-x1p - cxp) / rx,
    (-y1p - cyp) / ry,
  );
  if (!s.sweep && dt > 0) dt -= 2 * math.pi;
  if (s.sweep && dt < 0) dt += 2 * math.pi;
  final steps = math.max(4, (dt.abs() / (math.pi / 2) * 6).ceil());
  for (var k = 1; k <= steps; k++) {
    final t = t1 + dt * k / steps;
    final ex = rx * math.cos(t), ey = ry * math.sin(t);
    out.add((cos * ex - sin * ey + cx, sin * ex + cos * ey + cy));
  }
}

/// Flatten into closed polygons, one per subpath.
List<Poly> flattenPath(List<Segment> segs) {
  final polys = <Poly>[];
  var cur = <Pt>[];
  var px = 0.0, py = 0.0;
  for (final s in segs) {
    switch (s) {
      case MoveTo(:final x, :final y):
        if (cur.isNotEmpty) polys.add(cur);
        cur = [(x, y)];
        px = x;
        py = y;
      case LineTo(:final x, :final y):
        cur.add((x, y));
        px = x;
        py = y;
      case CubicTo():
        const n = 12;
        for (var k = 1; k <= n; k++) {
          final t = k / n, u = 1 - t;
          cur.add((
            u * u * u * px +
                3 * u * u * t * s.x1 +
                3 * u * t * t * s.x2 +
                t * t * t * s.x,
            u * u * u * py +
                3 * u * u * t * s.y1 +
                3 * u * t * t * s.y2 +
                t * t * t * s.y,
          ));
        }
        px = s.x;
        py = s.y;
      case QuadTo():
        const n = 8;
        for (var k = 1; k <= n; k++) {
          final t = k / n, u = 1 - t;
          cur.add((
            u * u * px + 2 * u * t * s.x1 + t * t * s.x,
            u * u * py + 2 * u * t * s.y1 + t * t * s.y,
          ));
        }
        px = s.x;
        py = s.y;
      case ArcTo():
        _sampleArc(px, py, s, cur);
        px = s.x;
        py = s.y;
      case Close():
        if (cur.isNotEmpty) {
          polys.add(cur);
          px = cur[0].$1;
          py = cur[0].$2;
        }
        cur = [];
    }
  }
  if (cur.isNotEmpty) polys.add(cur);
  return [
    for (final p in polys)
      if (p.length >= 3) p,
  ];
}

/// Nonzero winding number of a point against every polygon.
int winding(List<Poly> polys, double x, double y) {
  var w = 0;
  for (final poly in polys) {
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final (xi, yi) = poly[i];
      final (xj, yj) = poly[j];
      if (yj <= y) {
        if (yi > y && (xi - xj) * (y - yj) - (x - xj) * (yi - yj) > 0) w++;
      } else if (yi <= y && (xi - xj) * (y - yj) - (x - xj) * (yi - yj) < 0) {
        w--;
      }
    }
  }
  return w;
}

bool isInside(List<Poly> polys, double x, double y) =>
    winding(polys, x, y) != 0;

/// Nonzero inside flags for many points on one row ([xs] ascending), from
/// one pass over the edges rather than one winding test per point.
void insideRow(List<Poly> polys, double y, List<double> xs, Uint8List out) {
  final hits = <(double, int)>[];
  for (final poly in polys) {
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final (xj, yj) = poly[j];
      final (xi, yi) = poly[i];
      if (yj <= y && yi > y) {
        hits.add((xj + (y - yj) * (xi - xj) / (yi - yj), 1));
      } else if (yi <= y && yj > y) {
        hits.add((xj + (y - yj) * (xi - xj) / (yi - yj), -1));
      }
    }
  }
  hits.sort((a, b) => a.$1.compareTo(b.$1));
  var w = 0, h = 0;
  for (var k = 0; k < xs.length; k++) {
    while (h < hits.length && hits[h].$1 < xs[k]) {
      w += hits[h++].$2;
    }
    out[k] = w != 0 ? 1 : 0;
  }
}

/// An axis-aligned box.
class Bounds {
  const Bounds(this.minX, this.minY, this.maxX, this.maxY);

  final double minX, minY, maxX, maxY;

  double get width => maxX - minX;
  double get height => maxY - minY;
  Pt get center => ((minX + maxX) / 2, (minY + maxY) / 2);

  @override
  bool operator ==(Object other) =>
      other is Bounds &&
      other.minX == minX &&
      other.minY == minY &&
      other.maxX == maxX &&
      other.maxY == maxY;

  @override
  int get hashCode => Object.hash(minX, minY, maxX, maxY);
}

Bounds boundsOf(Iterable<Poly> polys) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final p in polys) {
    for (final (x, y) in p) {
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  return Bounds(minX, minY, maxX, maxY);
}

/// Filled area estimated on a one-unit grid (nonzero rule).
int filledArea(List<Poly> polys, [Bounds? b]) {
  b ??= boundsOf(polys);
  var n = 0;
  final xs = <double>[
    for (var x = b.minX.floorToDouble() + 0.5; x < b.maxX; x += 1) x,
  ];
  final row = Uint8List(xs.length);
  for (var y = b.minY.floorToDouble() + 0.5; y < b.maxY; y += 1) {
    insideRow(polys, y, xs, row);
    for (final v in row) {
      n += v;
    }
  }
  return n;
}

/// Normalised segments split into one list per subpath.
List<List<Segment>> splitSubpaths(List<Segment> segs) {
  final out = <List<Segment>>[];
  for (final s in segs) {
    if (s is MoveTo) out.add([]);
    if (out.isNotEmpty) out.last.add(s);
  }
  return out;
}
