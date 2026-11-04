// What a Bot Avatar is: one silhouette path in a 0..100 box and where its two
// eyes sit — geometry only. The validator and the body analysis are a port of
// Open Bot Avatar's `validate.ts` (MIT); the contract is the project's
// `docs/avatar-contract.md`, version 1.
import "dart:math" as math;
import "dart:typed_data";

import "path.dart";

/// Neutral eye size at scale 1, box units.
const eyeW = 4.0;
const eyeH = 11.0;

/// Hard limits on the body; the contract's soft target is 8..92.
const bodyMin = 6.0;
const bodyMax = 94.0;
const _eyeMargin = 1.2;

/// How far the eyes travel inside the face at scale 1. Small on purpose: a
/// subtle shift reads as looking around.
const gazeX = 1.5;
const gazeY = 1.1;

/// The happy eye's arc, as fractions of the drawn eye: a quadratic from
/// (x ∓ halfWidth·w, y + base·h) through (x, y − peak·h), stroked
/// stroke·w wide with round caps.
abstract final class HappyArc {
  static const halfWidth = 0.72;
  static const base = 0.1;
  static const peak = 0.42;
  static const stroke = 0.6;
}

/// The gap the renderer keeps between every drawn eye and the outline while
/// the eyes look around.
const eyeClearance = 1.5;

/// Where the pair of eyes sits on the body.
class BotAvatarEyes {
  const BotAvatarEyes({
    required this.x,
    required this.y,
    required this.spacing,
    required this.scale,
  });

  /// The pair's centre, box units.
  final double x, y;

  /// Centre to centre.
  final double spacing;

  /// 1 is a neutral eye about 4 wide and 11 tall.
  final double scale;

  BotAvatarEyes withScale(double scale) =>
      BotAvatarEyes(x: x, y: y, spacing: spacing, scale: scale);

  (Pt, Pt) get centers => ((x - spacing / 2, y), (x + spacing / 2, y));

  Map<String, Object> toJson() => {
    "x": _num(x),
    "y": _num(y),
    "spacing": _num(spacing),
    "scale": _num(scale),
  };

  @override
  bool operator ==(Object other) =>
      other is BotAvatarEyes &&
      other.x == x &&
      other.y == y &&
      other.spacing == spacing &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(x, y, spacing, scale);
}

/// A whole number written as one, so the JSON reads like the contract's.
num _num(double v) => v == v.truncateToDouble() ? v.toInt() : v;

/// A definition that has passed [BotAvatarDefinition.validate]: its path is
/// the normalised one, rebuilt from numbers.
class BotAvatarDefinition {
  const BotAvatarDefinition._({
    required this.id,
    required this.name,
    required this.path,
    required this.eyes,
    required this.body,
  });

  static const version = 1;

  /// A lowercase slug.
  final String id;

  /// A short display name.
  final String name;

  /// One filled path, nonzero rule.
  final String path;

  final BotAvatarEyes eyes;

  /// [path] taken apart, as validating it already had to: carried so the
  /// renderer does not parse and raster the same path again. Not part of
  /// equality, being [path]'s to say.
  final BodyAnalysis body;

  /// The definition JSON the contract describes, or the reasons it is not
  /// one. Unknown keys are refused, the way the reference validator does.
  static BotAvatarValidation validate(Object? input) {
    final errors = <String>[];
    if (input is! Map) {
      return const BotAvatarInvalid(["definition must be a JSON object"]);
    }
    for (final k in input.keys) {
      if (!_topKeys.contains(k)) {
        errors.add('unknown field "$k" (allowed: ${_topKeys.join(", ")})');
      }
    }
    if (input["version"] != 1) errors.add("version must be 1");

    final id = input["id"];
    if (id is! String || !_slug.hasMatch(id)) {
      errors.add("id must be a lowercase slug of 1-40 chars [a-z0-9-]");
    }
    final rawName = input["name"];
    final name = rawName is String ? rawName.trim() : "";
    if (name.isEmpty || name.length > 40 || _badName.hasMatch(name)) {
      errors.add("name must be 1-40 printable characters without < or >");
    }

    var path = "";
    final body = input["body"];
    if (body is! Map) {
      errors.add('body must be an object { "path": "..." }');
    } else {
      for (final k in body.keys) {
        if (k != "path") {
          errors.add('unknown field "body.$k" (only "path" is allowed)');
        }
      }
      final p = body["path"];
      if (p is! String) {
        errors.add("body.path must be a string");
      } else {
        path = p;
      }
    }

    BotAvatarEyes? eyes;
    final e = input["eyes"];
    if (e is! Map) {
      errors.add("eyes must be an object { x, y, spacing, scale }");
    } else {
      for (final k in e.keys) {
        if (!_eyeKeys.contains(k)) {
          errors.add(
            'unknown field "eyes.$k" (allowed: ${_eyeKeys.join(", ")})',
          );
        }
      }
      final bad = [
        for (final k in _eyeKeys)
          if (e[k] is! num || !(e[k] as num).isFinite) k,
      ];
      if (bad.isNotEmpty) {
        errors.add("eyes.${bad.join(", eyes.")} must be finite numbers");
      } else {
        eyes = BotAvatarEyes(
          x: (e["x"] as num).toDouble(),
          y: (e["y"] as num).toDouble(),
          spacing: (e["spacing"] as num).toDouble(),
          scale: (e["scale"] as num).toDouble(),
        );
        if (eyes.scale < 0.6 || eyes.scale > 1.8) {
          errors.add("eyes.scale ${_r1(eyes.scale)} out of range 0.6..1.8");
        }
        final minSpacing = eyeW * eyes.scale * 1.75;
        if (eyes.spacing < minSpacing || eyes.spacing > 40) {
          errors.add(
            "eyes.spacing ${_r1(eyes.spacing)} out of range "
            "${_r1(minSpacing)}..40 for scale ${_r1(eyes.scale)}",
          );
        }
      }
    }

    var normalized = "";
    BodyAnalysis? analysis;
    if (path.isNotEmpty) {
      try {
        normalized = serializePath(parsePath(path));
        analysis = BodyAnalysis.of(normalized);
      } on PathError catch (err) {
        errors.add("body.path: ${err.message}");
      }
    }

    if (analysis != null) {
      final b = analysis.bounds;
      final out = [
        if (b.minX < bodyMin) "left edge x=${_r1(b.minX)}",
        if (b.minY < bodyMin) "top edge y=${_r1(b.minY)}",
        if (b.maxX > bodyMax) "right edge x=${_r1(b.maxX)}",
        if (b.maxY > bodyMax) "bottom edge y=${_r1(b.maxY)}",
      ];
      if (out.isNotEmpty) {
        errors.add(
          "body.path leaves the safe area (${out.join(", ")}); keep "
          "geometry within 8..92",
        );
      }
      final w = b.width, h = b.height;
      if (math.max(w, h) < 40 || math.min(w, h) < 14) {
        errors.add(
          "body is too small (${_r1(w)}x${_r1(h)}); use at least 40 units on "
          "the long side and 14 on the short side",
        );
      }
      if (analysis.area < 600) {
        errors.add(
          "body fill area ${analysis.area} is too thin to carry eyes; must "
          "be at least 600 units²",
        );
      }
      if (eyes != null) {
        final miss = eyesFit(analysis.polys, eyes, 0, 0, _eyeMargin);
        if (miss != null) {
          errors.add(
            "eyes must sit inside the body with $_eyeMargin units margin; "
            "point (${_r1(miss.$1)}, ${_r1(miss.$2)}) is outside or in a "
            "hole. Move eyes.x/y toward the widest solid area, reduce "
            "spacing or scale.",
          );
        }
      }
    }

    if (errors.isNotEmpty || eyes == null) return BotAvatarInvalid(errors);
    return BotAvatarValid(
      BotAvatarDefinition._(
        id: id as String,
        name: name,
        path: normalized,
        eyes: eyes,
        body: analysis!,
      ),
    );
  }

  /// The definition JSON, as the contract writes it.
  Map<String, Object> toJson() => {
    "version": version,
    "id": id,
    "name": name,
    "body": {"path": path},
    "eyes": eyes.toJson(),
  };

  /// What makes two definitions draw the same: everything but the name.
  @override
  bool operator ==(Object other) =>
      other is BotAvatarDefinition &&
      other.id == id &&
      other.name == name &&
      other.path == path &&
      other.eyes == eyes;

  @override
  int get hashCode => Object.hash(id, name, path, eyes);
}

/// What [BotAvatarDefinition.validate] made of its input.
sealed class BotAvatarValidation {
  const BotAvatarValidation();
}

final class BotAvatarValid extends BotAvatarValidation {
  const BotAvatarValid(this.definition);
  final BotAvatarDefinition definition;
}

final class BotAvatarInvalid extends BotAvatarValidation {
  const BotAvatarInvalid(this.errors);
  final List<String> errors;
}

const _topKeys = ["version", "id", "name", "body", "eyes"];
const _eyeKeys = ["x", "y", "spacing", "scale"];
final _slug = RegExp(r"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$");
final _badName = RegExp(r"[\u0000-\u001f<>]");

String _r1(double n) {
  final r = (n * 10).round() / 10;
  return r == r.truncateToDouble() ? r.toInt().toString() : r.toString();
}

/// One subpath of a body: its own outline, and whether it cuts rather than
/// fills.
class BodySubpath {
  const BodySubpath({
    required this.polys,
    required this.hole,
    required this.probe,
  });

  final List<Poly> polys;
  final bool hole;

  /// For a hole, a point inside the cut: which outline it cuts.
  final Pt? probe;
}

/// A body path flattened and taken apart: its polygons, extent, area, and
/// which of its subpaths are holes.
class BodyAnalysis {
  const BodyAnalysis._({
    required this.polys,
    required this.bounds,
    required this.area,
    required this.subpaths,
  });

  factory BodyAnalysis.of(String path) {
    final segs = parsePath(path);
    final polys = flattenPath(segs);
    final b = boundsOf(polys);
    final subpaths = <BodySubpath>[];
    for (final sub in splitSubpaths(segs)) {
      final own = flattenPath(sub);
      if (own.isEmpty) continue;
      final ob = boundsOf(own);
      var inside = 0.0, cut = 0.0;
      Pt? cutProbe;
      // Small subpaths (buttons, sockets) want a fine grid.
      final step = ob.width * ob.height < 900 ? 0.5 : 1.0;
      final alone = own.length == polys.length;
      final xs = <double>[
        for (var x = ob.minX.floorToDouble() + step / 2; x < ob.maxX; x += step)
          x,
      ];
      final mine = Uint8List(xs.length), all = Uint8List(xs.length);
      for (var y = ob.minY.floorToDouble() + step / 2; y < ob.maxY; y += step) {
        insideRow(own, y, xs, mine);
        if (!alone) insideRow(polys, y, xs, all);
        for (var k = 0; k < xs.length; k++) {
          if (mine[k] == 0) continue;
          inside++;
          if (!alone && all[k] == 0) {
            cut++;
            cutProbe ??= (xs[k], y);
          }
        }
      }
      // A subpath mostly empty under the whole fill rule is a cut-out.
      final hole = inside > 0 && cut / inside > 0.6;
      subpaths.add(
        BodySubpath(polys: own, hole: hole, probe: hole ? cutProbe : null),
      );
    }
    return BodyAnalysis._(
      polys: polys,
      bounds: b,
      area: filledArea(polys, b),
      subpaths: subpaths,
    );
  }

  final List<Poly> polys;
  final Bounds bounds;
  final int area;
  final List<BodySubpath> subpaths;
}

/// How far, 0..1 of [gazeX] and [gazeY], the eyes can travel each way.
class GazeRange {
  const GazeRange(this.left, this.right, this.up, this.down);
  final double left, right, up, down;
}

/// Points on the outline of an eye pill grown by [margin].
List<Pt> _eyeOutline(double cx, double cy, double scale, double margin) {
  final hw = eyeW * scale / 2 + margin;
  final hh = eyeH * scale / 2 + margin;
  final straight = hh - hw;
  final pts = <Pt>[];
  for (var k = 0; k < 16; k++) {
    final a = k / 16 * math.pi * 2;
    final s = math.sin(a);
    pts.add((
      cx + math.cos(a) * hw,
      cy + s * hw + s.sign * math.max(0, straight),
    ));
  }
  for (final f in const [-0.5, 0.0, 0.5]) {
    pts
      ..add((cx - hw, cy + f * straight))
      ..add((cx + hw, cy + f * straight));
  }
  pts.add((cx, cy));
  return pts;
}

/// The outline of everything drawn for one eye — the pill and the wider
/// happy arc — grown by [margin].
List<Pt> _drawnEyeOutline(double cx, double cy, double scale, double margin) {
  final pts = _eyeOutline(cx, cy, scale, margin);
  final w = eyeW * scale, h = eyeH * scale;
  final x0 = cx - HappyArc.halfWidth * w, x1 = cx + HappyArc.halfWidth * w;
  final yb = cy + HappyArc.base * h, yc = cy - HappyArc.peak * h;
  final r = HappyArc.stroke * w / 2 + margin;
  for (var i = 0; i <= 8; i++) {
    final t = i / 8, m = 1 - t;
    final x = m * m * x0 + 2 * m * t * cx + t * t * x1;
    final y = (m * m + t * t) * yb + 2 * m * t * yc;
    for (var k = 0; k < 8; k++) {
      final a = k / 8 * math.pi * 2;
      pts.add((x + math.cos(a) * r, y + math.sin(a) * r));
    }
  }
  return pts;
}

/// The first point of either eye's pill that falls outside the body, or
/// null where both fit.
Pt? eyesFit(
  List<Poly> polys,
  BotAvatarEyes eyes,
  double dx,
  double dy,
  double margin,
) {
  final (a, b) = eyes.centers;
  for (final (cx, cy) in [a, b]) {
    for (final (x, y) in _eyeOutline(cx + dx, cy + dy, eyes.scale, margin)) {
      if (!isInside(polys, x, y)) return (x, y);
    }
  }
  return null;
}

/// [eyesFit] for everything the renderer may draw.
Pt? drawnEyesFit(
  List<Poly> polys,
  BotAvatarEyes eyes,
  double dx,
  double dy,
  double margin,
) {
  final (a, b) = eyes.centers;
  for (final (cx, cy) in [a, b]) {
    for (final (x, y) in _drawnEyeOutline(
      cx + dx,
      cy + dy,
      eyes.scale,
      margin,
    )) {
      if (!isInside(polys, x, y)) return (x, y);
    }
  }
  return null;
}

GazeRange gazeRange(List<Poly> polys, BotAvatarEyes eyes) {
  double reach(double ux, double uy) {
    for (final k in const [1.0, 0.8, 0.6, 0.4, 0.2]) {
      if (drawnEyesFit(
            polys,
            eyes,
            ux * k * gazeX * eyes.scale,
            uy * k * gazeY * eyes.scale,
            eyeClearance,
          ) ==
          null) {
        return k;
      }
    }
    return 0;
  }

  return GazeRange(reach(-1, 0), reach(1, 0), reach(0, -1), reach(0, 1));
}
