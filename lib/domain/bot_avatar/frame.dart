// One frame of a Bot Avatar, flattened onto the screen as plain data: every
// cross-section the view draws with its projection, and the eyes, back to
// front. A port of `avatarFrame` from Open Bot Avatar's `render.ts` (MIT);
// the painter that draws it is the UI's.
import "dart:math" as math;

import "definition.dart";
import "path.dart";
import "pose.dart";
import "volume.dart";

/// A 2D affine matrix in SVG order: x' = a·x + c·y + e, y' = b·x + d·y + f.
class Affine {
  const Affine(this.a, this.b, this.c, this.d, this.e, this.f);

  static const identity = Affine(1, 0, 0, 1, 0, 0);

  final double a, b, c, d, e, f;

  Affine operator *(Affine n) => Affine(
    a * n.a + c * n.b,
    b * n.a + d * n.b,
    a * n.c + c * n.d,
    b * n.c + d * n.d,
    a * n.e + c * n.f + e,
    b * n.e + d * n.f + f,
  );

  static Affine translate(double x, double y) => Affine(1, 0, 0, 1, x, y);

  /// [m] applied about the point ([x], [y]).
  static Affine about(double x, double y, Affine m) =>
      translate(x, y) * m * translate(-x, -y);
}

/// How one eye is drawn, in its face plane's box units.
sealed class EyeMark {
  const EyeMark();
}

/// An open eye: a rounded bar.
final class PillMark extends EyeMark {
  const PillMark(this.x, this.y, this.width, this.height, this.radius);
  final double x, y, width, height, radius;
}

/// A happy eye: a quadratic arc from ([x0], [y]) through ([cx], [cy]) to
/// ([x1], [y]), stroked [strokeWidth] wide with round caps.
final class ArcMark extends EyeMark {
  const ArcMark(this.x0, this.x1, this.y, this.cx, this.cy, this.strokeWidth);
  final double x0, x1, y, cx, cy, strokeWidth;
}

sealed class FrameShape {
  const FrameShape(this.matrix);
  final Affine matrix;
}

/// A cross-section, filled in the body colour.
final class SliceShape extends FrameShape {
  const SliceShape(this.slice, super.matrix);
  final VolumeSlice slice;
}

/// An eye, drawn in the ink.
final class EyeShapeMark extends FrameShape {
  const EyeShapeMark(this.index, this.mark, super.matrix);
  final int index;
  final EyeMark mark;
}

/// One frame: paint [shapes] in order, inside [root], in a 0..100 box.
class BotAvatarFrame {
  const BotAvatarFrame(this.root, this.shapes);

  /// The hop, roll and squash about the foot of the body.
  final Affine root;

  /// Back to front.
  final List<FrameShape> shapes;
}

/// How far the eyes sit above the surface, so the body's planes never
/// touch them.
const _eyeLift = 1.5;

/// The least facing for an eye to be drawn.
const _eyeFacing = 0.22;

class _View {
  _View(double yaw, double pitch)
    : cY = math.cos(yaw),
      sY = math.sin(yaw),
      cP = math.cos(pitch),
      sP = math.sin(pitch);

  final double cY, sY, cP, sP;

  /// The toward-viewer part of a model-space direction.
  double facing(Vec3 n) => sP * n.$2 + cP * (-sY * n.$1 + cY * n.$3);

  SliceAxis get stack => cY.abs() >= sY.abs() ? SliceAxis.z : SliceAxis.x;

  /// The plane at depth [z], pivoting on [pivot] at z = 0: yaw about the
  /// vertical axis, then pitch about the horizontal.
  Affine plane(double z, Pt pivot) {
    final (cx, cy) = pivot;
    return Affine(
      cY,
      sY * sP,
      0,
      cP,
      cx - cY * cx + sY * z,
      cy - cP * cy - sY * sP * cx - cY * sP * z,
    );
  }

  /// The side plane x = [x0], whose local coordinates are (u = −z, y).
  Affine side(double x0, Pt pivot) {
    final (cx, cy) = pivot;
    return Affine(
      -sY,
      cY * sP,
      0,
      cP,
      cx + cY * (x0 - cx),
      cy - cP * cy + sY * sP * (x0 - cx),
    );
  }

  /// Depth toward the viewer of a 3D point.
  double depth(Vec3 p, Pt pivot) {
    final x = p.$1 - pivot.$1, y = p.$2 - pivot.$2;
    return sP * y + cP * (-sY * x + cY * p.$3);
  }
}

/// A validated definition with its volume built, ready to draw any frame
/// of. Building the volume is the expensive part, so instances are cached by
/// definition, the most recent kept.
class PreparedBotAvatar {
  PreparedBotAvatar._(this.definition, this.volume)
    : _range = gazeRange(
        definition.body.polys,
        definition.eyes.withScale(volume.eyeScale),
      ),
      _seed = hashString(definition.id);

  /// [definition] prepared, from the cache where it is there.
  factory PreparedBotAvatar.of(BotAvatarDefinition definition) {
    final hit = _cache.remove(definition);
    if (hit != null) return _cache[definition] = hit;
    if (_cache.length >= 64) _cache.remove(_cache.keys.first);
    return _cache[definition] = PreparedBotAvatar._(
      definition,
      Volume.build(definition),
    );
  }

  static final _cache = <BotAvatarDefinition, PreparedBotAvatar>{};

  final BotAvatarDefinition definition;
  final Volume volume;
  final GazeRange _range;
  final int _seed;

  /// The frame at [time] seconds in [mood].
  BotAvatarFrame frame({
    double time = 0,
    BotMood mood = BotMood.idle,
    Gaze? gaze,
    ViewTurn view = ViewTurn.none,
    MoodBlend? blend,
    bool reducedMotion = false,
  }) {
    final pose = computePose(
      seed: _seed,
      time: time,
      mood: mood,
      gaze: gaze,
      reducedMotion: reducedMotion,
      view: view,
      blend: blend,
    );
    final vol = volume;
    final b = vol.bounds;
    final pivot = b.center;
    final v = _View(pose.yaw, pose.pitch);
    final stack = v.stack;
    final eyesMid = (definition.eyes.x, definition.eyes.y);

    // Screen shift per unit of depth, and the least on-screen size of an
    // in-plane inset: z-slices hidden behind the core add nothing.
    final sweep = math.sqrt(v.sY * v.sY + v.cY * v.sP * v.cY * v.sP);
    final insetScale = math.min(v.cY.abs(), v.cP.abs());
    bool drawn(VolumeSlice s) =>
        s.axis != SliceAxis.z ||
        s.inset <= 0 ||
        s.at.abs() * sweep > s.inset * insetScale;

    final items = <(double, FrameShape)>[];
    for (var i = 0; i < vol.parts.length; i++) {
      final part = vol.parts[i];
      // The eye part's depth keys are taken under the eyes, so depth alone
      // decides eye against body there.
      final (rx, ry) = i == vol.eyePart ? eyesMid : part.center;
      for (final s in stack == SliceAxis.z ? part.zSlices : part.xSlices) {
        if (!drawn(s)) continue;
        final z = stack == SliceAxis.z;
        items.add((
          z ? v.depth((rx, ry, s.at), pivot) : v.depth((s.at, ry, 0), pivot),
          SliceShape(s, z ? v.plane(s.at, pivot) : v.side(s.at, pivot)),
        ));
      }
    }
    final marks = _eyeMarks(pose);
    final (n0, n1) = vol.eyeNormals;
    final (z0, z1) = vol.eyeZ;
    for (final (idx, normals, z) in [(0, n0, z0), (1, n1, z1)]) {
      if (!normals.every((n) => v.facing(n) > _eyeFacing)) continue;
      final lifted = z + _eyeLift;
      items.add((
        v.depth((eyesMid.$1, eyesMid.$2, lifted), pivot) + 1e-6,
        EyeShapeMark(idx, marks[idx], v.plane(lifted, pivot)),
      ));
    }
    // A stable sort, as the reference's: equal depths keep their order.
    final order = List.generate(items.length, (i) => i)
      ..sort((x, y) {
        final c = items[x].$1.compareTo(items[y].$1);
        return c != 0 ? c : x.compareTo(y);
      });
    return BotAvatarFrame(_root(pose, b), [for (final i in order) items[i].$2]);
  }

  List<EyeMark> _eyeMarks(Pose pose) {
    final s = volume.eyeScale;
    final w = eyeW * s, h = eyeH * s;
    final r = _range;
    final dx = pose.gazeX * (pose.gazeX >= 0 ? r.right : r.left) * gazeX * s;
    final dy = pose.gazeY * (pose.gazeY >= 0 ? r.down : r.up) * gazeY * s;
    final (c0, c1) = definition.eyes.centers;
    return [
      for (final (i, (x, y)) in [(0, c0), (1, c1)])
        if (pose.eyeShape == EyeShape.happy)
          ArcMark(
            x + dx - w * HappyArc.halfWidth,
            x + dx + w * HappyArc.halfWidth,
            y + dy + h * HappyArc.base,
            x + dx,
            y + dy - h * HappyArc.peak,
            w * HappyArc.stroke,
          )
        else
          _pill(
            x + dx,
            y + dy,
            w,
            h,
            i == 0 ? pose.squintL : pose.squintR,
            pose.blink,
          ),
    ];
  }

  static PillMark _pill(
    double x,
    double y,
    double w,
    double h,
    double squint,
    double blink,
  ) {
    final open = math.max(
      h * math.max(0.09, (1 - blink) * (1 - squint * 0.4)),
      w * 0.55,
    );
    // Lids close toward a point a little below the centre.
    final cy = y + (h - open) * 0.18;
    return PillMark(x - w / 2, cy - open / 2, w, open, math.min(w, open) / 2);
  }

  static Affine _root(Pose pose, Bounds b) {
    final bx = (b.minX + b.maxX) / 2, by = b.maxY;
    final r = pose.roll * math.pi / 180;
    final rot = Affine(
      math.cos(r),
      math.sin(r),
      -math.sin(r),
      math.cos(r),
      0,
      0,
    );
    return Affine.translate(0, pose.lift) *
        Affine.about(bx, by, rot * Affine(pose.sx, 0, 0, pose.sy, 0, 0));
  }
}
