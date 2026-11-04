// Iso-contours of a sampled field (marching squares), joined into closed
// loops and simplified: how a part's depth field becomes plain cross-section
// polygons. A port of Open Bot Avatar's `contour.ts` (MIT).
import "dart:math" as math;
import "dart:typed_data";

import "path.dart";

/// Row-major samples, [nx] by [ny], from ([x0], [y0]) every [step]. The
/// outermost ring should sit below every level asked for.
class Field {
  const Field(this.values, this.nx, this.ny, this.x0, this.y0, this.step);

  final Float64List values;
  final int nx, ny;
  final double x0, y0, step;
}

/// Closed loops where [field] crosses [level] (inside is at or above it).
List<Poly> contourLoops(Field field, double level) {
  final Field(:values, :nx, :ny, :x0, :y0, :step) = field;
  double at(int i, int j) => values[j * nx + i] - level;
  // Edge keys: horizontal (i,j)-(i+1,j) is 2*(j*nx+i), vertical
  // (i,j)-(i,j+1) is 2*(j*nx+i)+1.
  final points = <int, Pt>{};
  final links = <int, List<int>>{};
  void point(int key) {
    if (points.containsKey(key)) return;
    final idx = key >> 1, i = idx % nx, j = (idx - i) ~/ nx;
    final a = at(i, j);
    if (key & 1 == 1) {
      final b = at(i, j + 1), t = a / (a - b);
      points[key] = (x0 + i * step, y0 + (j + t) * step);
    } else {
      final b = at(i + 1, j), t = a / (a - b);
      points[key] = (x0 + (i + t) * step, y0 + j * step);
    }
  }

  void link(int p, int q) {
    point(p);
    point(q);
    (links[p] ??= []).add(q);
    (links[q] ??= []).add(p);
  }

  for (var j = 0; j < ny - 1; j++) {
    for (var i = 0; i < nx - 1; i++) {
      final tl = at(i, j) >= 0, tr = at(i + 1, j) >= 0;
      final br = at(i + 1, j + 1) >= 0, bl = at(i, j + 1) >= 0;
      final code = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0);
      if (code == 0 || code == 15) continue;
      final top = 2 * (j * nx + i), bottom = 2 * ((j + 1) * nx + i);
      final left = 2 * (j * nx + i) + 1, right = 2 * (j * nx + i + 1) + 1;
      if (code == 10 || code == 5) {
        final center =
            (at(i, j) + at(i + 1, j) + at(i + 1, j + 1) + at(i, j + 1)) / 4 >=
            0;
        // Diagonal corners: the centre decides whether they join through.
        if ((code == 10) == center) {
          link(top, right);
          link(bottom, left);
        } else {
          link(left, top);
          link(right, bottom);
        }
        continue;
      }
      final crossed = <int>[
        if (tl != tr) top,
        if (tr != br) right,
        if (br != bl) bottom,
        if (bl != tl) left,
      ];
      link(crossed[0], crossed[1]);
    }
  }

  final loops = <Poly>[];
  final seen = <int>{};
  for (final start in links.keys) {
    if (seen.contains(start)) continue;
    final loop = <Pt>[];
    var prev = -1, cur = start;
    while (!seen.contains(cur)) {
      seen.add(cur);
      loop.add(points[cur]!);
      int? next;
      for (final n in links[cur]!) {
        if (n != prev && !seen.contains(n)) {
          next = n;
          break;
        }
      }
      if (next == null) break;
      prev = cur;
      cur = next;
    }
    if (loop.length >= 3) loops.add(loop);
  }
  return loops;
}

double _perpendicular(Pt p, Pt a, Pt b) {
  final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) {
    final ex = p.$1 - a.$1, ey = p.$2 - a.$2;
    return math.sqrt(ex * ex + ey * ey);
  }
  return (dx * (a.$2 - p.$2) - dy * (a.$1 - p.$1)).abs() / len;
}

/// Ramer–Douglas–Peucker on a closed loop.
Poly simplifyLoop(Poly loop, double tolerance) {
  if (loop.length <= 8) return loop;
  // Split at the point farthest from the first: two open chains.
  var far = 0;
  var best = -1.0;
  for (var k = 1; k < loop.length; k++) {
    final dx = loop[k].$1 - loop[0].$1, dy = loop[k].$2 - loop[0].$2;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d > best) {
      best = d;
      far = k;
    }
  }
  final keep = Uint8List(loop.length);
  keep[0] = keep[far] = 1;
  final stack = <(int, int)>[(0, far), (far, loop.length)];
  while (stack.isNotEmpty) {
    final (s, e) = stack.removeLast();
    final end = loop[e % loop.length];
    var idx = -1;
    var max = tolerance;
    for (var k = s + 1; k < e; k++) {
      final d = _perpendicular(loop[k], loop[s], end);
      if (d > max) {
        max = d;
        idx = k;
      }
    }
    if (idx >= 0) {
      keep[idx] = 1;
      stack
        ..add((s, idx))
        ..add((idx, e));
    }
  }
  return [
    for (var k = 0; k < loop.length; k++)
      if (keep[k] == 1) loop[k],
  ];
}
