import 'dart:convert';
import 'dart:typed_data';

typedef _Cell = (int, int, int);

class _Face {
  const _Face(
    this.dx,
    this.dy,
    this.dz,
    this.nx,
    this.ny,
    this.nz,
    this.a,
    this.b,
    this.c,
    this.d,
  );

  final int dx, dy, dz;
  final double nx, ny, nz;
  final int a, b, c, d;
}

const _faces = <_Face>[
  _Face(1, 0, 0, 1, 0, 0, 1, 3, 7, 5),
  _Face(-1, 0, 0, -1, 0, 0, 0, 4, 6, 2),
  _Face(0, 1, 0, 0, 1, 0, 2, 6, 7, 3),
  _Face(0, -1, 0, 0, -1, 0, 0, 1, 5, 4),
  _Face(0, 0, 1, 0, 0, 1, 4, 5, 7, 6),
  _Face(0, 0, -1, 0, 0, -1, 0, 2, 3, 1),
];

/// Converts RoomScope XYZ points (metres, Y-up) into a closed binary STL.
/// The STL is Z-up, millimetres, and uses occupied voxels so slicers receive
/// triangles rather than an unprintable point cloud.
Uint8List buildVoxelStl(Float32List xyz) {
  if (xyz.isEmpty || xyz.length % 3 != 0) {
    throw const FormatException('No valid RoomScope points to export.');
  }

  var voxelSize = 0.04;
  Set<_Cell> occupied = <_Cell>{};
  for (var attempt = 0; attempt < 8; attempt++) {
    occupied = _voxelize(xyz, voxelSize);
    if (occupied.length <= 60000) break;
    voxelSize *= 1.25;
  }
  if (occupied.isEmpty) {
    throw const FormatException('The scan contains no finite 3D points.');
  }

  // Remove one-off speckles while preserving connected surfaces/furniture.
  if (occupied.length > 16) {
    final filtered = occupied
        .where((cell) => _hasNeighbour(cell, occupied))
        .toSet();
    if (filtered.length >= 8) occupied = filtered;
  }

  var minX = occupied.first.$1;
  var minY = occupied.first.$2;
  var minZ = occupied.first.$3;
  var maxZ = occupied.first.$3;
  for (final cell in occupied) {
    if (cell.$1 < minX) minX = cell.$1;
    if (cell.$2 < minY) minY = cell.$2;
    if (cell.$3 < minZ) minZ = cell.$3;
    if (cell.$3 > maxZ) maxZ = cell.$3;
  }

  var triangleCount = 0;
  for (final cell in occupied) {
    for (final face in _faces) {
      if (!occupied.contains((
        cell.$1 + face.dx,
        cell.$2 + face.dy,
        cell.$3 + face.dz,
      ))) {
        triangleCount += 2;
      }
    }
  }
  if (triangleCount == 0) {
    throw const FormatException('The scan did not produce an STL surface.');
  }

  final bytes = Uint8List(84 + triangleCount * 50);
  final header = utf8.encode(
    'RoomScope closed voxel mesh; Z-up; units millimetres; binary STL',
  );
  final headerLength = header.length < 80 ? header.length : 80;
  bytes.setRange(0, headerLength, header);
  final data = ByteData.view(bytes.buffer);
  data.setUint32(80, triangleCount, Endian.little);

  final mm = voxelSize * 1000.0;
  final depthExtent = (maxZ - minZ + 1) * mm;
  var offset = 84;
  for (final cell in occupied) {
    final x0 = (cell.$1 - minX) * mm;
    final y0 = (cell.$2 - minY) * mm;
    final z0 = (cell.$3 - minZ) * mm;
    final x1 = x0 + mm;
    final y1 = y0 + mm;
    final z1 = z0 + mm;
    for (final face in _faces) {
      if (occupied.contains((
        cell.$1 + face.dx,
        cell.$2 + face.dy,
        cell.$3 + face.dz,
      ))) {
        continue;
      }
      offset = _writeTriangle(
        data,
        offset,
        face,
        face.a,
        face.b,
        face.c,
        x0,
        y0,
        z0,
        x1,
        y1,
        z1,
        depthExtent,
      );
      offset = _writeTriangle(
        data,
        offset,
        face,
        face.a,
        face.c,
        face.d,
        x0,
        y0,
        z0,
        x1,
        y1,
        z1,
        depthExtent,
      );
    }
  }
  return bytes;
}

Set<_Cell> _voxelize(Float32List xyz, double size) {
  final cells = <_Cell>{};
  for (var i = 0; i + 2 < xyz.length; i += 3) {
    final x = xyz[i].toDouble();
    final y = xyz[i + 1].toDouble();
    final z = xyz[i + 2].toDouble();
    if (!x.isFinite || !y.isFinite || !z.isFinite) continue;
    cells.add(((x / size).floor(), (y / size).floor(), (z / size).floor()));
  }
  return cells;
}

bool _hasNeighbour(_Cell cell, Set<_Cell> cells) {
  for (var dx = -1; dx <= 1; dx++) {
    for (var dy = -1; dy <= 1; dy++) {
      for (var dz = -1; dz <= 1; dz++) {
        if (dx == 0 && dy == 0 && dz == 0) continue;
        if (cells.contains((cell.$1 + dx, cell.$2 + dy, cell.$3 + dz))) {
return true;
        }
      }
    }
  }
  return false;
}

int _writeTriangle(
  ByteData data,
  int offset,
  _Face face,
  int a,
  int b,
  int c,
  double x0,
  double y0,
  double z0,
  double x1,
  double y1,
  double z1,
  double depthExtent,
) {
  void writeFloat(double value) {
    data.setFloat32(offset, value, Endian.little);
    offset += 4;
  }

  // World (X,Y,Z with Y-up) -> STL (X,-Z,Y with Z-up).
  writeFloat(face.nx);
  writeFloat(-face.nz);
  writeFloat(face.ny);

  for (final corner in [a, b, c]) {
    final wx = (corner & 1) == 0 ? x0 : x1;
    final wy = (corner & 2) == 0 ? y0 : y1;
    final wz = (corner & 4) == 0 ? z0 : z1;
    writeFloat(wx);
    writeFloat(depthExtent - wz);
    writeFloat(wy);
  }
  data.setUint16(offset, 0, Endian.little);
  return offset + 2;
}
