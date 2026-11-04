// The volume a flat silhouette implies. A port of Open Bot Avatar's
// `volume.ts` (MIT).
//
// The definition stays a 2D path. Each filled subpath becomes a part with a
// front-surface height field h(x, y), the back mirroring it about z = 0:
//
// - inflate: a rounded slab, its height an elliptical fillet of the distance
//   to the outline, so the sides curve and the face is flat;
// - revolve-y: turned about the part's own vertical centre line (a mug, a
//   pot), from exact scanline widths;
// - revolve-x: turned about one horizontal axis the whole body shares (a
//   barbell's bar and plates).
//
// From the field each part is cut, once, into two stacks of plain
// cross-sections: z-slices facing the viewer (level sets of h) and x-slices
// facing sideways (column profiles of h). Painted in one flat colour, a
// stack's union is the solid's silhouette; the renderer shows whichever stack
// faces the viewer more, so no plane is ever seen edge-on.
import "dart:math" as math;
import "dart:typed_data";

import "contour.dart";
import "definition.dart";
import "path.dart";

enum PartKind { inflate, revolveX, revolveY }

enum SliceAxis { z, x }

/// One cross-section: the plane z = [at] with loops in (x, y), or the plane
/// x = [at] with loops in (u = −z, y).
class VolumeSlice {
  const VolumeSlice({
    required this.axis,
    required this.at,
    required this.loops,
    required this.evenOdd,
    required this.inset,
  });

  final SliceAxis axis;
  final double at;
  final List<Poly> loops;

  /// Contours fill even-odd; the core reuses the outline's nonzero rule.
  final bool evenOdd;

  /// For z-slices, the least distance from this section to the outline —
  /// 0 for the core and the walls.
  final double inset;

  VolumeSlice atDepth(double at) => VolumeSlice(
    axis: axis,
    at: at,
    loops: loops,
    evenOdd: evenOdd,
    inset: inset,
  );
}

class VolumePart {
  const VolumePart({
    required this.kind,
    required this.polys,
    required this.bounds,
    required this.center,
    required this.zSlices,
    required this.xSlices,
    required this.height,
  });

  final PartKind kind;
  final List<Poly> polys;
  final Bounds bounds;
  final Pt center;
  final List<VolumeSlice> zSlices;
  final List<VolumeSlice> xSlices;

  /// The front surface's height at a point, 0 outside the part.
  final double Function(double x, double y) height;
}

typedef Vec3 = (double, double, double);

class Volume {
  const Volume({
    required this.parts,
    required this.bounds,
    required this.eyePart,
    required this.eyeZ,
    required this.eyeScale,
    required this.eyeNormals,
  });

  final List<VolumePart> parts;
  final Bounds bounds;

  /// The part carrying the eyes.
  final int eyePart;

  /// Each eye's plane: the highest surface under it and its gaze travel.
  final (double, double) eyeZ;

  /// The drawn eye scale: the definition's, grown as far as the body allows.
  final double eyeScale;

  /// The host's surface normals under each eye (left edge, centre, right
  /// edge): an eye is hidden once any of them turns away.
  final (List<Vec3>, List<Vec3>) eyeNormals;

  /// Build the volume of [def]. [volume] scales every depth, 0 being flat.
  factory Volume.build(
    BotAvatarDefinition def, {
    double volume = 1,
    BodyAnalysis? body,
  }) => _build(def, volume, body ?? BodyAnalysis.of(def.path));
}

/// The deepest an inflated part may be, box units.
const maxPartDepth = 30.0;

/// Drawn eyes are up to this much bigger than the contract's 4 × 11 pill.
const eyeBoost = 1.45;

/// The gap every drawn eye keeps from the outline before it is enlarged.
const eyeBoostPad = 3.0;

const _outlineSlope = 4.0;
const _maxXSlices = 40;
const _thin = 4.0;
const _thinReach = 5.0;
const _thinMargin = 2.0;
const _fineZ = 0.6;

double _segDist(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final len = dx * dx + dy * dy;
  var t = len > 0 ? ((px - ax) * dx + (py - ay) * dy) / len : 0.0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  final ex = ax + t * dx - px, ey = ay + t * dy - py;
  return math.sqrt(ex * ex + ey * ey);
}

/// The distance from a point to the nearest edge.
double edgeDistance(List<Poly> polys, double x, double y) {
  var best = double.infinity;
  for (final poly in polys) {
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final d = _segDist(x, y, poly[j].$1, poly[j].$2, poly[i].$1, poly[i].$2);
      if (d < best) best = d;
    }
  }
  return best;
}

/// An inflated part's front surface, [dist] units inside the outline.
double _surfaceZ(double depth, double rxy, double rz, double dist) {
  final half = depth / 2;
  if (rxy <= 0 || dist >= rxy) return half;
  final k = 1 - math.max(0, dist) / rxy;
  return half - rz + math.sqrt(math.max(0, 1 - k * k)) * rz;
}

/// As deep as the part is thick, but a tall slender part up to 2.4 times,
/// so it reads as a disc.
double _partDepth(double thickness, Bounds b, double volume) {
  final long = math.max(b.width, b.height);
  final raw = 0.8 * math.max(thickness, math.min(0.4 * long, 2.4 * thickness));
  return math.min(maxPartDepth, math.max(3, raw)) * volume;
}

/// Sorted crossings of y = s (rows) or x = s with the polygons.
List<double> _crossings(List<Poly> polys, bool rows, double s) {
  final out = <double>[];
  for (final poly in polys) {
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final p = poly[j], q = poly[i];
      final pa = rows ? p.$2 : p.$1, qa = rows ? q.$2 : q.$1;
      final pb = rows ? p.$1 : p.$2, qb = rows ? q.$1 : q.$2;
      if ((pa <= s && qa > s) || (qa <= s && pa > s)) {
        out.add(pb + (s - pa) * (qb - pb) / (qa - pa));
      }
    }
  }
  return out..sort();
}

class _Profile {
  const _Profile(this.start, this.step, this.r);
  final double start, step;
  final Float64List r;

  double radiusAt(double s) {
    final t = (s - start) / step;
    if (t < 0 || t > r.length - 1) return 0;
    final k = math.min(r.length - 2, t.floor());
    return r[k] + (r[k + 1] - r[k]) * (t - k);
  }
}

/// Half-widths about [center] along rows (or columns), where every line
/// crosses the part as one interval centred on it; otherwise null.
_Profile? _revolveProfile(
  List<Poly> polys,
  bool rows,
  double lo,
  double hi,
  double center,
) {
  const step = 0.2;
  final n = math.max(2, ((hi - lo) / step).ceil() + 1);
  final r = Float64List(n);
  var span = 0.0;
  final mids = <double>[];
  for (var k = 0; k < n; k++) {
    final s = math.min(hi - 0.01, math.max(lo + 0.01, lo + k * step));
    final xs = _crossings(polys, rows, s);
    if (xs.isEmpty) continue;
    if (xs.length != 2) return null;
    r[k] = (xs[1] - xs[0]) / 2;
    span = math.max(span, xs[1] - xs[0]);
    mids.add((xs[0] + xs[1]) / 2);
  }
  final tol = math.max(0.8, 0.04 * span);
  if (mids.isEmpty || mids.any((m) => (m - center).abs() > tol)) return null;
  return _Profile(lo, step, r);
}

/// The horizontal axis a body turns about, if it looks like a turned object
/// seen from the side: two or more parts, wider than tall, mirror-symmetric
/// about the axis, every part centred on it.
double? _revolveAxis(BodyAnalysis body) {
  final b = body.bounds;
  final outlines = [
    for (final s in body.subpaths)
      if (!s.hole) s,
  ];
  if (outlines.length < 2 || b.width < 1.1 * b.height) return null;
  final axis = (b.minY + b.maxY) / 2;
  for (final o in outlines) {
    final ob = boundsOf(o.polys);
    if (((ob.minY + ob.maxY) / 2 - axis).abs() > 1.5) return null;
  }
  var filled = 0, off = 0;
  final xs = <double>[for (var x = b.minX + 0.5; x < b.maxX; x += 1) x];
  final top = Uint8List(xs.length), bottom = Uint8List(xs.length);
  for (var y = b.minY + 0.5; y < axis; y += 1) {
    insideRow(body.polys, y, xs, top);
    insideRow(body.polys, 2 * axis - y, xs, bottom);
    for (var k = 0; k < xs.length; k++) {
      if (top[k] != 0 || bottom[k] != 0) filled++;
      if (top[k] != bottom[k]) off++;
    }
  }
  return filled > 0 && off / filled < 0.02 ? axis : null;
}

/// Signed distance (positive inside) and height sampled over a part.
class _Grid {
  const _Grid(this.x0, this.y0, this.step, this.nx, this.ny, this.sd, this.h);
  final double x0, y0, step;
  final int nx, ny;
  final Float64List sd, h;
}

/// Edges bucketed on a coarse grid, so a nearest-edge query visits only
/// the buckets near it.
class _EdgeIndex {
  _EdgeIndex(List<Poly> polys, Bounds b)
    : _ox = b.minX - 4,
      _oy = b.minY - 4,
      _span = ((math.max(b.width, b.height) + 8) / _cell).ceil() + 1 {
    for (final poly in polys) {
      for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        final k = _e.length;
        _e.addAll([poly[j].$1, poly[j].$2, poly[i].$1, poly[i].$2]);
        final x0 = math.min(poly[j].$1, poly[i].$1);
        final x1 = math.max(poly[j].$1, poly[i].$1);
        final y0 = math.min(poly[j].$2, poly[i].$2);
        final y1 = math.max(poly[j].$2, poly[i].$2);
        for (var cy = _cy(y0); cy <= _cy(y1); cy++) {
          for (var cx = _cx(x0); cx <= _cx(x1); cx++) {
            (_buckets[cy * _span + cx] ??= []).add(k);
          }
        }
      }
    }
  }

  static const _cell = 3.0;
  final _buckets = <int, List<int>>{};
  final _e = <double>[];
  final double _ox, _oy;
  final int _span;

  int _cx(double x) => ((x - _ox) / _cell).floor().clamp(0, _span - 1);
  int _cy(double y) => ((y - _oy) / _cell).floor().clamp(0, _span - 1);

  /// The nearest edge, searching rings of buckets outward until no nearer
  /// one can exist.
  double distance(double x, double y) {
    final bx = _cx(x), by = _cy(y);
    var best = double.infinity;
    for (var r = 0; r < _span; r++) {
      for (var cy = by - r; cy <= by + r; cy++) {
        if (cy < 0 || cy >= _span) continue;
        final edgeRow = cy == by - r || cy == by + r;
        final stride = edgeRow ? 1 : (2 * r == 0 ? 1 : 2 * r);
        for (var cx = bx - r; cx <= bx + r; cx += stride) {
          if (cx < 0 || cx >= _span) continue;
          final list = _buckets[cy * _span + cx];
          if (list == null) continue;
          for (final k in list) {
            final d = _segDist(x, y, _e[k], _e[k + 1], _e[k + 2], _e[k + 3]);
            if (d < best) best = d;
          }
        }
      }
      // Every bucket outside ring r is at least r cells away.
      if (best <= r * _cell) break;
    }
    return best;
  }
}

_Grid _sampleGrid(
  List<Poly> polys,
  Bounds b,
  double step,
  double Function(double x, double y, double sd) height,
) {
  const pad = 1.0;
  final x0 = b.minX - pad, y0 = b.minY - pad;
  final nx = ((b.width + 2 * pad) / step).ceil() + 1;
  final ny = ((b.height + 2 * pad) / step).ceil() + 1;
  final sd = Float64List(nx * ny), h = Float64List(nx * ny);
  final index = _EdgeIndex(polys, b);
  final xs = [for (var i = 0; i < nx; i++) x0 + i * step];
  final inside = Uint8List(nx);
  for (var j = 0; j < ny; j++) {
    final y = y0 + j * step;
    insideRow(polys, y, xs, inside);
    for (var i = 0; i < nx; i++) {
      final d = index.distance(xs[i], y);
      final k = j * nx + i;
      sd[k] = inside[i] != 0 ? d : -d;
      h[k] = inside[i] != 0 ? height(xs[i], y, d) : 0;
    }
  }
  return _Grid(x0, y0, step, nx, ny, sd, h);
}

/// A rectangle of grid samples, inclusive, and the highest surface over
/// the thin samples in it.
class _Box {
  const _Box(this.i0, this.i1, this.j0, this.j1, [this.top = 0]);
  final int i0, i1, j0, j1;
  final double top;
}

/// The section {h ≥ level}, clipped to the outline and to [box] if given.
List<Poly> _levelLoops(_Grid g, double level, [_Box? box]) {
  final i0 = box != null ? math.max(0, box.i0 - 1) : 0;
  final i1 = box != null ? math.min(g.nx - 1, box.i1 + 1) : g.nx - 1;
  final j0 = box != null ? math.max(0, box.j0 - 1) : 0;
  final j1 = box != null ? math.min(g.ny - 1, box.j1 + 1) : g.ny - 1;
  final nx = i1 - i0 + 1, ny = j1 - j0 + 1;
  final values = Float64List(nx * ny);
  for (var j = 0; j < ny; j++) {
    for (var i = 0; i < nx; i++) {
      final k = (j + j0) * g.nx + i + i0;
      var v = math.min(g.h[k] - level, _outlineSlope * g.sd[k]);
      if (box != null) {
        final edge = [
          i + i0 - box.i0,
          box.i1 - i - i0,
          j + j0 - box.j0,
          box.j1 - j - j0,
        ].reduce(math.min);
        v = math.min(v, _outlineSlope * g.step * edge);
      }
      values[j * nx + i] = v;
    }
  }
  return [
    for (final l in contourLoops(
      Field(values, nx, ny, g.x0 + i0 * g.step, g.y0 + j0 * g.step, g.step),
      0,
    ))
      if (simplifyLoop(l, 0.04) case final s when s.length >= 3) s,
  ];
}

/// Boxes round the thin parts of an outline — where no inscribed circle
/// within [_thinReach] has a radius of [_thin] — grown and merged. A thin,
/// deep fin seen at an angle shifts more between slices than it is wide, and
/// without refinement slices fans out into copies.
List<_Box> _thinBoxes(_Grid g) {
  final nx = g.nx, ny = g.ny;
  final reach = (_thinReach / g.step).ceil();
  final rows = Float64List(nx * ny), widest = Float64List(nx * ny);
  for (var j = 0; j < ny; j++) {
    for (var i = 0; i < nx; i++) {
      var m = 0.0;
      final e = math.min(nx - 1, i + reach);
      for (var k = math.max(0, i - reach); k <= e; k++) {
        m = math.max(m, g.sd[j * nx + k]);
      }
      rows[j * nx + i] = m;
    }
  }
  for (var i = 0; i < nx; i++) {
    for (var j = 0; j < ny; j++) {
      var m = 0.0;
      final e = math.min(ny - 1, j + reach);
      for (var k = math.max(0, j - reach); k <= e; k++) {
        m = math.max(m, rows[k * nx + i]);
      }
      widest[j * nx + i] = m;
    }
  }
  bool thin(int k) => g.sd[k] > 0 && widest[k] < _thin;
  final seen = Uint8List(nx * ny);
  final grow = (_thinMargin / g.step).ceil();
  final boxes = <_Box>[];
  for (var start = 0; start < nx * ny; start++) {
    if (seen[start] != 0 || !thin(start)) continue;
    var bi0 = nx, bi1 = -1, bj0 = ny, bj1 = -1;
    var top = 0.0;
    var cells = 0;
    final stack = [start];
    seen[start] = 1;
    while (stack.isNotEmpty) {
      final k = stack.removeLast();
      final i = k % nx, j = (k - i) ~/ nx;
      cells++;
      top = math.max(top, g.h[k]);
      bi0 = math.min(bi0, i);
      bi1 = math.max(bi1, i);
      bj0 = math.min(bj0, j);
      bj1 = math.max(bj1, j);
      for (final n in [
        i > 0 ? k - 1 : -1,
        i < nx - 1 ? k + 1 : -1,
        j > 0 ? k - nx : -1,
        j < ny - 1 ? k + nx : -1,
      ]) {
        if (n >= 0 && seen[n] == 0 && thin(n)) {
          seen[n] = 1;
          stack.add(n);
        }
      }
    }
    // Specks are not worth a slice.
    if (cells * g.step * g.step < 2) continue;
    boxes.add(
      _Box(
        math.max(0, bi0 - grow),
        math.min(nx - 1, bi1 + grow),
        math.max(0, bj0 - grow),
        math.min(ny - 1, bj1 + grow),
        top,
      ),
    );
  }
  // Overlapping boxes become one, so no section is drawn twice.
  for (var a = 0; a < boxes.length; a++) {
    for (var b = a + 1; b < boxes.length; b++) {
      final p = boxes[a], q = boxes[b];
      if (p.i0 > q.i1 || q.i0 > p.i1 || p.j0 > q.j1 || q.j0 > p.j1) continue;
      boxes[a] = _Box(
        math.min(p.i0, q.i0),
        math.max(p.i1, q.i1),
        math.min(p.j0, q.j0),
        math.max(p.j1, q.j1),
        math.max(p.top, q.top),
      );
      boxes.removeAt(b);
      b = a;
    }
  }
  return boxes;
}

/// The side profile of the slab of columns [c0]..[c1], drawn as one plane:
/// loops in (u = −z, y), symmetric in u. Each row takes the slab's greatest
/// height, so a stack of these seen side-on adds up to the side silhouette;
/// where a run meets the outline the profile ends at the surface height
/// right there ([edgeHeight]) rather than the last sample's.
List<Poly> _columnLoops(
  _Grid g,
  int c0,
  int c1,
  double Function(double x, double y) edgeHeight,
) {
  final loops = <Poly>[];
  final sd = Float64List(g.ny)..fillRange(0, g.ny, double.negativeInfinity);
  final h = Float64List(g.ny);
  for (var j = 0; j < g.ny; j++) {
    for (var c = c0; c <= c1; c++) {
      final k = j * g.nx + c;
      if (g.sd[k] > sd[j]) sd[j] = g.sd[k];
      if (g.sd[k] > 0 && g.h[k] > h[j]) h[j] = g.h[k];
    }
  }
  double yAt(int jj) => g.y0 + jj * g.step;
  double edge(int inside, int outside) =>
      yAt(inside) +
      (yAt(outside) - yAt(inside)) * sd[inside] / (sd[inside] - sd[outside]);
  double rim(double y, int j) {
    var top = 0.0;
    for (var c = c0; c <= c1; c++) {
      top = math.max(top, edgeHeight(g.x0 + c * g.step, y));
    }
    return math.min(h[j], top);
  }

  var j = 0;
  while (j < g.ny) {
    if (sd[j] <= 0) {
      j++;
      continue;
    }
    final j0 = j;
    while (j < g.ny && sd[j] > 0) {
      j++;
    }
    final j1 = j - 1;
    final yTop = j0 > 0 ? edge(j0, j0 - 1) : yAt(j0);
    final yBot = j1 < g.ny - 1 ? edge(j1, j1 + 1) : yAt(j1);
    final right = <Pt>[
      (j0 > 0 ? rim(yTop, j0) : h[j0], yTop),
      for (var k = j0; k <= j1; k++) (h[k], yAt(k)),
      (j1 < g.ny - 1 ? rim(yBot, j1) : h[j1], yBot),
    ];
    if (right.map((p) => p.$1).reduce(math.max) < 0.05) continue;
    final left = [for (final (u, y) in right.reversed) (-u, y)];
    loops.add(simplifyLoop([...right, ...left], 0.04));
  }
  return loops;
}

/// Depth levels in (flat, flat + round), even in angle over the round.
List<double> _levels(double flat, double round, int steps) => [
  for (var k = 1; k < steps; k++)
    flat + round * math.sin(k / steps * (math.pi / 2)),
];

Volume _build(BotAvatarDefinition def, double volume, BodyAnalysis body) {
  final outlines = [
    for (final s in body.subpaths)
      if (!s.hole) s,
  ];
  final holes = [
    for (final s in body.subpaths)
      if (s.hole) s,
  ];
  final v = volume.isFinite ? math.max(0.0, volume) : 1.0;
  final xAxis = _revolveAxis(body);

  final parts = <VolumePart>[];
  for (final o in outlines) {
    final cuts = [
      for (final h in holes)
        if (h.probe case final p? when isInside(o.polys, p.$1, p.$2)) h,
    ];
    final polys = [...o.polys, for (final h in cuts) ...h.polys];
    final b = boundsOf(o.polys);
    final center = b.center;
    final minDim = math.min(b.width, b.height);
    final step = math.max(0.25, math.min(0.45, minDim / 24));

    // Classify: a shared horizontal axis, an own vertical one (several-part
    // bodies only), or inflated.
    var kind = PartKind.inflate;
    _Profile? profile;
    if (xAxis != null) {
      profile = _revolveProfile(polys, false, b.minX, b.maxX, xAxis);
      if (profile != null) kind = PartKind.revolveX;
    } else if (outlines.length > 1 && cuts.isEmpty) {
      profile = _revolveProfile(polys, true, b.minY, b.maxY, center.$1);
      if (profile != null) kind = PartKind.revolveY;
    }

    double depth, rz = 0;
    double Function(double x, double y, double sd) heightOf;
    if (kind == PartKind.inflate || profile == null) {
      final coarse = _sampleGrid(polys, b, math.max(step, 0.6), (_, _, _) => 0);
      final thickness = 2 * coarse.sd.fold<double>(0, math.max);
      depth = _partDepth(thickness, b, v);
      final rxy = math.min(thickness / 2, depth / 2) * 0.9;
      rz = depth / 2 * 0.85;
      final d = depth, r = rz;
      heightOf = (_, _, sd) => _surfaceZ(d, rxy, r, sd);
    } else {
      final p = profile;
      final axis = kind == PartKind.revolveX ? xAxis! : center.$1;
      final radius = p.r.fold<double>(0, math.max);
      depth = 2 * radius * v;
      heightOf = kind == PartKind.revolveX
          ? (x, y, _) =>
                v *
                math.sqrt(
                  math.max(
                    0,
                    math.pow(p.radiusAt(x), 2) - (y - axis) * (y - axis),
                  ),
                )
          : (x, y, _) =>
                v *
                math.sqrt(
                  math.max(
                    0,
                    math.pow(p.radiusAt(y), 2) - (x - axis) * (x - axis),
                  ),
                );
    }
    final inflate = kind == PartKind.inflate;
    double height(double x, double y) => isInside(polys, x, y)
        ? heightOf(x, y, inflate ? edgeDistance(polys, x, y) : 0)
        : 0;

    final zSlices = <VolumeSlice>[
      VolumeSlice(
        axis: SliceAxis.z,
        at: 0,
        loops: polys,
        evenOdd: false,
        inset: 0,
      ),
    ];
    final xSlices = <VolumeSlice>[];
    final half = depth / 2;
    if (half > 0.05) {
      final g = _sampleGrid(polys, b, step, heightOf);
      final steps = inflate
          ? (rz / 0.8).round().clamp(4, 14)
          : (half / 1.1).round().clamp(5, 18);
      // An inflated part keeps a straight wall up to half − rz; one slice at
      // its end carries it.
      final ls = inflate
          ? [half - rz, ..._levels(half - rz, rz, steps)]
          : _levels(0, half, steps);
      bool addLevel(double level, [_Box? box]) {
        final loops = _levelLoops(g, level, box);
        if (loops.isEmpty) return false;
        var inset = double.infinity;
        var k = 0;
        for (final loop in loops) {
          for (final (x, y) in loop) {
            if (k++ % 3 == 0) {
              inset = math.min(inset, edgeDistance(polys, x, y));
            }
          }
        }
        final slice = VolumeSlice(
          axis: SliceAxis.z,
          at: level,
          loops: loops,
          evenOdd: true,
          inset: inset,
        );
        zSlices
          ..add(slice)
          ..add(slice.atDepth(-level));
        return true;
      }

      final used = [0.0];
      for (final level in ls) {
        if (level >= 0.02 && addLevel(level)) used.add(level);
      }
      // Thin parts of an inflated outline get more sections between the
      // levels, each clipped to its box.
      for (final box in inflate ? _thinBoxes(g) : const <_Box>[]) {
        for (var k = 1; k < used.length && used[k - 1] < box.top; k++) {
          final a = used[k - 1], gap = used[k] - a;
          final m = (gap / _fineZ - 1e-9).ceil();
          for (var q = 1; q < m && a + gap * q / m < box.top; q++) {
            addLevel(a + gap * q / m, box);
          }
        }
      }
      zSlices.sort((m, n) => m.at.compareTo(n.at));

      final every = math.max(
        1,
        (math.max(1.1, b.width / _maxXSlices) / g.step).round(),
      );
      double edgeHeight(double x, double y) => heightOf(x, y, 0);
      // One plane per `every` columns, standing for the slab round it.
      final before = (every - 1) ~/ 2;
      for (var i = 1; i < g.nx - 1; i += every) {
        final loops = _columnLoops(
          g,
          math.max(0, i - before),
          math.min(g.nx - 1, i - before + every - 1),
          edgeHeight,
        );
        if (loops.isNotEmpty) {
          xSlices.add(
            VolumeSlice(
              axis: SliceAxis.x,
              at: g.x0 + i * g.step,
              loops: loops,
              evenOdd: true,
              inset: 0,
            ),
          );
        }
      }
    }

    parts.add(
      VolumePart(
        kind: kind,
        polys: polys,
        bounds: b,
        center: center,
        zSlices: zSlices,
        xSlices: xSlices,
        height: height,
      ),
    );
  }

  final eyeScale = boostedEyeScale(body, def.eyes);
  // The eyes ride whichever part is highest under their centres.
  final (c0, c1) = def.eyes.centers;
  final centers = [c0, c1];
  var eyePart = 0;
  var bestZ = double.negativeInfinity;
  for (var i = 0; i < parts.length; i++) {
    final zs = [for (final (x, y) in centers) parts[i].height(x, y)];
    if (zs.any((z) => z <= 0)) continue;
    final z = math.min(zs[0], zs[1]);
    if (z > bestZ) {
      bestZ = z;
      eyePart = i;
    }
  }
  final host = parts.isEmpty ? null : parts[eyePart];
  // A flat eye plane sits at the highest surface under the eye and its gaze
  // travel, so the body never cuts it.
  final w = eyeW * eyeScale / 2 + gazeX * eyeScale;
  final hh = eyeH * eyeScale / 2 + gazeY * eyeScale;
  double eyeZ((double, double) c) {
    var top = 0.0;
    for (final fx in const [-1.0, -0.5, 0.0, 0.5, 1.0]) {
      for (final fy in const [-1.0, -0.5, 0.0, 0.5, 1.0]) {
        top = math.max(top, host?.height(c.$1 + fx * w, c.$2 + fy * hh) ?? 0);
      }
    }
    return top;
  }

  Vec3 normal(double x, double y) {
    if (host == null) return (0, 0, 1);
    const e = 0.75;
    final gx = (host.height(x + e, y) - host.height(x - e, y)) / (2 * e);
    final gy = (host.height(x, y + e) - host.height(x, y - e)) / (2 * e);
    final n = math.sqrt(gx * gx + gy * gy + 1);
    return (-gx / n, -gy / n, 1 / n);
  }

  final halfEye = eyeW * eyeScale / 2;
  List<Vec3> normals(Pt c) => [
    normal(c.$1 - halfEye, c.$2),
    normal(c.$1, c.$2),
    normal(c.$1 + halfEye, c.$2),
  ];

  return Volume(
    parts: parts,
    bounds: body.bounds,
    eyePart: eyePart,
    eyeZ: (eyeZ(c0), eyeZ(c1)),
    eyeScale: eyeScale,
    eyeNormals: (normals(c0), normals(c1)),
  );
}

/// The largest eye scale, up to [eyeBoost] times the definition's, whose
/// drawn eyes keep [eyeBoostPad] from the outline.
double boostedEyeScale(BodyAnalysis body, BotAvatarEyes eyes) {
  for (final k in const [eyeBoost, 1.38, 1.3, 1.22, 1.15, 1.08]) {
    if (drawnEyesFit(
          body.polys,
          eyes.withScale(eyes.scale * k),
          0,
          0,
          eyeBoostPad,
        ) ==
        null) {
      return eyes.scale * k;
    }
  }
  return eyes.scale;
}
