import 'dart:math' as math;
import 'dart:typed_data';

class Point3 {
  const Point3(
    this.x,
    this.y,
    this.z, [
    this.r = 76,
    this.g = 225,
    this.b = 177,
  ]);
  final double x, y, z;
  final int r, g, b;
}

class MappingFrame {
  MappingFrame(Map<String, dynamic> data)
    : timestamp = (data['timestamp'] as num).toDouble(),
      tracking = data['tracking'] == true,
      pose = (data['pose'] as List).map((e) => (e as num).toDouble()).toList(),
      intrinsics = (data['intrinsics'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
      anchors = (data['anchors'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
      points = (data['points'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
      rgb = data['rgb'] as Uint8List?;
  final double timestamp;
  final bool tracking;
  final List<double> pose, intrinsics, anchors, points;
  final Uint8List? rgb;
  bool get valid =>
      timestamp.isFinite &&
      pose.length == 16 &&
      pose.every((n) => n.isFinite) &&
      intrinsics.length == 4 &&
      intrinsics.every((n) => n.isFinite) &&
      intrinsics[0] > 0 &&
      intrinsics[1] > 0;
}

// ARCore and ARKit use a right-handed camera frame looking along -Z.
// Pose matrices are camera-to-world, column-major. Image Y points down.
Point3 unproject(
  double u,
  double v,
  double depth,
  List<double> k,
  List<double> pose, [
  List<int>? color,
]) {
  final x = (u - k[2]) * depth / k[0];
  final y = -(v - k[3]) * depth / k[1];
  final z = -depth;
  return Point3(
    pose[0] * x + pose[4] * y + pose[8] * z + pose[12],
    pose[1] * x + pose[5] * y + pose[9] * z + pose[13],
    pose[2] * x + pose[6] * y + pose[10] * z + pose[14],
    color?[0] ?? 76,
    color?[1] ?? 225,
    color?[2] ?? 177,
  );
}

class DepthFit {
  const DepthFit(this.scale, this.offset, this.relativeError);
  final double scale, offset, relativeError;
  double metricDepth(double inversePrediction) =>
      1 / (scale * inversePrediction + offset);
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  if (sorted.isEmpty) return double.infinity;
  return sorted[sorted.length ~/ 2];
}

// MiDaS is relative inverse depth. Solve metric scale AND shift against
// same-frame tracked anchors. Reject weak fits instead of inventing metres.
DepthFit? fitDepth(
  List<double> prediction,
  List<double> anchors, {
  int width = 256,
  int height = 256,
}) {
  if (prediction.length != width * height) return null;
  var samples = <(double, double)>[];
  for (var i = 0; i + 2 < anchors.length; i += 3) {
    final u = anchors[i], v = anchors[i + 1], z = anchors[i + 2];
    if (!u.isFinite ||
        !v.isFinite ||
        !z.isFinite ||
        z < .25 ||
        z > 8 ||
        u < 0 ||
        v < 0 ||
        u >= width ||
        v >= height) {
      continue;
    }
    final p = prediction[v.floor() * width + u.floor()];
    if (p.isFinite) samples.add((p, 1 / z));
  }
  if (samples.length < 16) return null;
  final depths = samples.map((s) => 1 / s.$2).toList()..sort();
  if (depths[(depths.length * .9).floor()] -
          depths[(depths.length * .1).floor()] <
      .2) {
    return null;
  }
  var a = 0.0, b = 0.0;
  for (var pass = 0; pass < 3; pass++) {
    if (samples.length < 12) return null;
    final mx = samples.fold(0.0, (s, p) => s + p.$1) / samples.length;
    final my = samples.fold(0.0, (s, p) => s + p.$2) / samples.length;
    var variance = 0.0, covariance = 0.0;
    for (final p in samples) {
      variance += (p.$1 - mx) * (p.$1 - mx);
      covariance += (p.$1 - mx) * (p.$2 - my);
    }
    if (variance < 1e-10) return null;
    a = covariance / variance;
    b = my - a * mx;
    if (!a.isFinite || !b.isFinite || a <= 0) return null;
    final residuals = samples.map((p) => (a * p.$1 + b - p.$2).abs()).toList();
    final limit = math.max(.015, 3 * _median(residuals));
    samples = samples
        .where((p) => (a * p.$1 + b - p.$2).abs() <= limit)
        .toList();
  }
  final error = _median(
    samples.map((p) => (a * p.$1 + b - p.$2).abs() / p.$2).toList(),
  );
  return error <= .15 ? DepthFit(a, b, error) : null;
}

class VoxelMap {
  VoxelMap({this.voxelSize = .04, this.maxPoints = 100000});
  final double voxelSize;
  final int maxPoints;
  final Map<(int, int, int), Point3> _voxels = {};
  Iterable<Point3> get points => _voxels.values;
  int get length => _voxels.length;
  void clear() => _voxels.clear();
  void add(Point3 p) {
    if (![p.x, p.y, p.z].every((v) => v.isFinite)) return;
    final key = (
      (p.x / voxelSize).floor(),
      (p.y / voxelSize).floor(),
      (p.z / voxelSize).floor(),
    );
    if (!_voxels.containsKey(key) && _voxels.length >= maxPoints) return;
    _voxels[key] = p;
  }

  void addTracked(MappingFrame frame) {
    if (!frame.valid || !frame.tracking) return;
    for (var i = 0; i + 2 < frame.points.length; i += 3) {
      add(Point3(frame.points[i], frame.points[i + 1], frame.points[i + 2]));
    }
  }

  DepthFit? addPredicted(MappingFrame frame, List<double> prediction) {
    if (!frame.valid || !frame.tracking) return null;
    final fit = fitDepth(prediction, frame.anchors);
    if (fit == null) return null;
    for (var v = 4; v < 256; v += 8) {
      for (var u = 4; u < 256; u += 8) {
        final z = fit.metricDepth(prediction[v * 256 + u]);
        if (!z.isFinite || z < .25 || z > 8) continue;
        final index = (v * 256 + u) * 3;
        final rgb = frame.rgb;
        add(
          unproject(
            u.toDouble(),
            v.toDouble(),
            z,
            frame.intrinsics,
            frame.pose,
            rgb == null ? null : [rgb[index], rgb[index + 1], rgb[index + 2]],
          ),
        );
      }
    }
    return fit;
  }

  String toPly() {
    final out = StringBuffer(
      'ply\nformat ascii 1.0\n'
      'comment RoomScope metres; right-handed world; estimated geometry\n'
      'element vertex $length\nproperty float x\nproperty float y\n'
      'property float z\nproperty uchar red\nproperty uchar green\n'
      'property uchar blue\nend_header\n',
    );
    for (final p in points) {
      out.writeln(
        '${p.x.toStringAsFixed(5)} ${p.y.toStringAsFixed(5)} '
        '${p.z.toStringAsFixed(5)} ${p.r} ${p.g} ${p.b}',
      );
    }
    return out.toString();
  }
}
